:html_theme.sidebar_secondary.remove:

Memory management
=================

Tarantool has a number of memory managers used for different purposes.
They include **slab_arena**, **slab_cache** system, **mempool**,
**small** allocator, **region** allocator and **matras**, which are
organized hierarchically. To understand what it really means, you need
to pass through the following guide. Let's start from the **arena**, as
far as it is the root of this hierarchy.


..  _arena:

Arena
-----

Arena is responsible for allocating relatively large aligned memory
blocks (called **slabs**) of the given size. It also preallocates quite
a lot of memory (depending on overall **quota**).

..  _arena-definition:

Arena definition
~~~~~~~~~~~~~~~~

..  code:: c

    /**
     * slab_arena -- a source of large aligned blocks of memory.
     * MT-safe.
     * Uses a lock-free LIFO to maintain a cache of used slabs.
     * Uses a lock-free quota to limit allocating memory.
     * Never returns memory to the operating system.
     */
    struct slab_arena {
        /**
        * A lock free list of cached slabs.
        * Initially there are no cached slabs, only arena.
        * As slabs are used and returned to arena, the cache is
        * used to recycle them.
        */
        struct lf_lifo cache;
        /** A preallocated arena of size = prealloc. */
        void *arena;
        /**
        * How much memory is preallocated during initialization
        * of slab_arena.
        */
        size_t prealloc;
        /**
        * How much memory in the arena has
        * already been initialized for slabs.
        */
        size_t used;
        /**
        * An external quota to which we must adhere.
        * A quota exists to set a common limit on two arenas.
        */
        struct quota *quota;
        /*
        * Each object returned by arena_map() has this size.
        * The size is provided at arena initialization.
        * It must be a power of 2 and large enough
        * (at least 64kb, since the two lower bytes are
        * used for ABA counter in the lock-free list).
        * Returned pointers are always aligned by this size.
        *
        * It's important to keep this value moderate to
        * limit the overhead of partially populated slabs.
        * It is still necessary, however, to make it settable,
        * to allow allocation of large objects.
        * Typical value is 4Mb, which makes it possible to
        * allocate objects of size up to ~1MB.
        */
        uint32_t slab_size;
        /**
        * SLAB_ARENA_ flags for mmap() and madvise() calls.
        */
        int flags;
    };

..  _arena-methods:

Arena methods
~~~~~~~~~~~~~

Arena is created with specific **quota**, **slab** size and preallocated
memory. It uses mmap for allocation.

..  code:: c

    int
    slab_arena_create(struct slab_arena *arena, struct quota *quota,
                      size_t prealloc, uint32_t slab_size, int flags)
    {
        lf_lifo_init(&arena->cache);
        VALGRIND_MAKE_MEM_DEFINED(&arena->cache, sizeof(struct lf_lifo));

        /*
        * Round up the user supplied data - it can come in
        * directly from the configuration file. Allow
        * zero-size arena for testing purposes.
        */
        arena->slab_size = small_round(MAX(slab_size, SLAB_MIN_SIZE));

        arena->quota = quota;
        /** Prealloc can not be greater than the quota */
        prealloc = MIN(prealloc, quota_total(quota));
        /** Extremely large sizes can not be aligned properly */
        prealloc = MIN(prealloc, SIZE_MAX - arena->slab_size);
        /* Align prealloc around a fixed number of slabs. */
        arena->prealloc = small_align(prealloc, arena->slab_size);

        arena->used = 0;

        slab_arena_flags_init(arena, flags);

        if (arena->prealloc) {
            arena->arena = mmap_checked(arena->prealloc,
                                        arena->slab_size,
                                        arena->flags);
        } else {
            arena->arena = NULL;
        }

        madvise_checked(arena->arena, arena->prealloc, arena->flags);

        return arena->prealloc && !arena->arena ? -1 : 0;
    }

..  _slab_map:

Most importantly, arena allows us to map a **slab**. First, we check the
list of returned **slabs**, called **arena** cache (not **slab cache**),
which contains previously used and now emptied slabs. If there are no
such **slabs**, we confirm that **quota** limit is fulfilled and then
either take **slab** from the **preallocated** area or allocate it.

..  code:: c

    void *
    slab_map(struct slab_arena *arena)
    {
        void *ptr;
        if ((ptr = lf_lifo_pop(&arena->cache))) {
            VALGRIND_MAKE_MEM_UNDEFINED(ptr, arena->slab_size);
            return ptr;
        }

        if (quota_use(arena->quota, arena->slab_size) < 0)
            return NULL;

        /** Need to allocate a new slab. */
        size_t used = pm_atomic_fetch_add(&arena->used, arena->slab_size);
        used += arena->slab_size;
        if (used <= arena->prealloc) {
            ptr = arena->arena + used - arena->slab_size;
            VALGRIND_MAKE_MEM_UNDEFINED(ptr, arena->slab_size);
            return ptr;
        }

        ptr = mmap_checked(arena->slab_size, arena->slab_size,
                       arena->flags);
        if (!ptr) {
            __sync_sub_and_fetch(&arena->used, arena->slab_size);
            quota_release(arena->quota, arena->slab_size);
        }

        madvise_checked(ptr, arena->slab_size, arena->flags);

        VALGRIND_MAKE_MEM_UNDEFINED(ptr, arena->slab_size);
        return ptr;
    }

..  _slab_unmap:

Of course, we can also return one to an **arena**. In this case, we push
it into the previously mentioned list of returned **slabs** to get it
back faster next time.

..  code:: c

    void
    slab_unmap(struct slab_arena *arena, void *ptr)
    {
        if (ptr == NULL)
            return;

        lf_lifo_push(&arena->cache, ptr);
        VALGRIND_MAKE_MEM_NOACCESS(ptr, arena->slab_size);
        VALGRIND_MAKE_MEM_DEFINED(lf_lifo(ptr), sizeof(struct lf_lifo));
    }

..  _slab-cache:

Slab cache
----------

Slab cache allows us to get a piece of **arena slab** with the size
close to needed. It implements a buddy system, which means that we get
**slabs** of the size that is a power of 2 (**arena slab**, size of which
is also power of 2, is being divided until we get a chunk of the
appropriate size, or we just get the corresponding already available chunk),
and then, when it is freed, we look for its **neighbour (buddy)** to
**merge** them, if the neighbour is also free, to avoid
**fragmentation**.

..  _slab-cache-definition:

Slab & slab cache definition
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    struct slab {
        /*
        * Next slab in the list of allocated slabs. Unused if
        * this slab has a buddy. Sic: if a slab is not allocated
        * but is made by a split of a larger (allocated) slab,
        * this member got to be left intact, to not corrupt
        * cache->allocated list.
        */
        struct rlist next_in_cache;
        /** Next slab in slab_list->slabs list. */
        struct rlist next_in_list;
        /**
        * Allocated size.
        * Is different from (SLAB_MIN_SIZE << slab->order)
        * when requested size is bigger than SLAB_MAX_SIZE
        * (i.e. slab->order is SLAB_CLASS_LAST).
        */
        size_t size;
        /** Slab magic (for sanity checks). */
        uint32_t magic;
        /** Base of lb(size) for ordered slabs. */
        uint8_t order;
        /**
        * Only used for buddy slabs. If the buddy of the current
        * free slab is also free, both slabs are merged and
        * a free slab of the higher order emerges.
        * Value of 0 means the slab is free. Otherwise
        * slab->in_use is set to slab->order + 1.
        */
        uint8_t in_use;
    };

    /**
     * A general purpose list of slabs. Is used
     * to store unused slabs of a certain order in the
     * slab cache, as well as to contain allocated
     * slabs of a specialized allocator.
     */
    struct slab_list {
        struct rlist slabs;
        /** Total/used bytes in this list. */
        struct small_stats stats;
    };

    /*
     * A binary logarithmic distance between the smallest and
     * the largest slab in the cache can't be that big, really.
     */
    enum { ORDER_MAX = 16 };

    struct slab_cache {
        /* The source of allocations for this cache. */
        struct slab_arena *arena;
        /*
        * Min size of the slab in the cache maintained
        * using the buddy system. The logarithmic distance
        * between order0_size and arena->slab_max_size
        * defines the number of "orders" of slab cache.
        * This distance can't be more than ORDER_MAX.
        */
        uint32_t order0_size;
        /*
        * Binary logarithm of order0_size, useful in pointer
        * arithmetics.
        */
        uint8_t order0_size_lb;
        /*
        * Slabs of order in range [0, order_max) have size
        * which is a power of 2. Slabs in the next order are
        * double the size of the previous order.  Slabs of the
        * previous order are obtained by splitting a slab of the
        * next order, and so on until order is order_max
        * Slabs of order order_max are obtained directly
        * from slab_arena. This system is also known as buddy
        * system.
        */
        uint8_t order_max;
        /** All allocated slabs used in the cache.
        * The stats reflect the total used/allocated
        * memory in the cache.
        */
        struct slab_list allocated;
        /**
        * Lists of unused slabs, for each slab order.
        *
        * A used slab is removed from the list and its
        * next_in_list link may be reused for some other purpose.
        */
        struct slab_list orders[ORDER_MAX+1];
    #ifndef _NDEBUG
        pthread_t thread_id;
    #endif
    };

..  _slab-cache-methods:

Slab cache methods
~~~~~~~~~~~~~~~~~~

..  _slab_get_with_order:

Most importantly, it allows us to acquire a **slab** of needed
**order**. We first look through **orders** array of **slab** lists,
starting from the given **order**. We can use slabs of higher **order**.
In case nothing is found, we are trying to get a new **arena slab**
using previously described **arena** method :ref:`slab_map <slab_map>`. We
preprocess it and add it to the corresponding lists. Then we are
splitting the **slab** if the **order** doesn't match exactly.

.. code:: c

   struct slab *
   slab_get_with_order(struct slab_cache *cache, uint8_t order)
   {
        assert(order <= cache->order_max);
        struct slab *slab;
        /* Search for the first available slab. If a slab
        * of a bigger size is found, it can be split.
        * If cache->order_max is reached and there are no
        * free slabs, allocate a new one on arena.
        */
        struct slab_list *list= &cache->orders[order];

        for ( ; rlist_empty(&list->slabs); list++) {
            if (list == cache->orders + cache->order_max) {
                    slab = slab_map(cache->arena);
                    if (slab == NULL)
                            return NULL;
                    slab_create(slab, cache->order_max,
                                cache->arena->slab_size);
                    slab_poison(slab);
                    slab_list_add(&cache->allocated, slab,
                                  next_in_cache);
                    slab_list_add(list, slab, next_in_list);
                    break;
            }
        }
        slab = rlist_shift_entry(&list->slabs, struct slab, next_in_list);
        if (slab->order != order) {
            /*
                * Do not "bill" the size of this slab to this
                * order, to prevent double accounting of the
                * same memory.
                */
            list->stats.total -= slab->size;
            /* Get a slab of the right order. */
            do {
                    slab = slab_split(cache, slab);
            } while (slab->order != order);
            /*
                * Count the slab in this order. The buddy is
                * already taken care of by slab_split.
                */
            cache->orders[slab->order].stats.total += slab->size;
        }
        slab_set_used(cache, slab);
        slab_assert(cache, slab);
        return slab;
    }

..  _slab_get_large:

There is an option to get a **slab** of the **order** bigger than
**order_max**. It will be allocated independently using **malloc**.

..  code:: c

    struct slab *
    slab_get_large(struct slab_cache *cache, size_t size)
    {
        size += slab_sizeof();
        if (quota_use(cache->arena->quota, size) < 0)
            return NULL;
        struct slab *slab = (struct slab *) malloc(size);
        if (slab == NULL) {
            quota_release(cache->arena->quota, size);
            return NULL;
        }

        slab_create(slab, cache->order_max + 1, size);
        slab_list_add(&cache->allocated, slab, next_in_cache);
        cache->allocated.stats.used += size;
        VALGRIND_MEMPOOL_ALLOC(cache, slab_data(slab),
                           slab_capacity(slab));
        return slab;
    }

..  _slab_put_large:

Large **slabs** are being freed when not needed anymore, there is no
**cache** or something like that for them.

..  code:: c

    void
    slab_put_large(struct slab_cache *cache, struct slab *slab)
    {
        slab_assert(cache, slab);
        assert(slab->order == cache->order_max + 1);
        /*
        * Free a huge slab right away, we have no
        * further business to do with it.
        */
        size_t slab_size = slab->size;
        slab_list_del(&cache->allocated, slab, next_in_cache);
        cache->allocated.stats.used -= slab_size;
        quota_release(cache->arena->quota, slab_size);
        slab_poison(slab);
        VALGRIND_MEMPOOL_FREE(cache, slab_data(slab));
        free(slab);
        return;
    }

When the normal **slab** is being emptied, it is processed in a more
specific way, as mentioned above. We get its **buddy** (neighbour
**slab** of the same size, which complements current **slab** to the
**slab** of the next **order**). If **buddy** is not in use and is not
split into smaller parts, we **merge** them and get free **slab** of the
next **order**, thus avoiding fragmentation. If we get an **arena slab**
as the result, we return it to **arena** using its method
:ref`slab_unmap <slab_unmap>` in case there is already an **arena slab**
in **cache**. Otherwise, we leave it in **slab cache** to avoid extra
moves.

..  code:: c

    /** Return a slab back to the slab cache. */
    void
    slab_put_with_order(struct slab_cache *cache, struct slab *slab)
    {
        slab_assert(cache, slab);
        assert(slab->order <= cache->order_max);
        /* An "ordered" slab is returned to the cache. */
        slab_set_free(cache, slab);
        struct slab *buddy = slab_buddy(cache, slab);
        /*
        * The buddy slab could also have been split into a pair
        * of smaller slabs, the first of which happens to be
        * free. To not merge with a slab which is in fact
        * partially occupied, first check that slab orders match.
        *
        * A slab is not accounted in "used" or "total" counters
        * if it was split into slabs of a lower order.
        * cache->orders statistics only contains sizes of either
        * slabs returned by slab_get, or present in the free
        * list. This ensures that sums of cache->orders[i].stats
        * match the totals in cache->allocated.stats.
        */
        if (buddy && buddy->order == slab->order && slab_is_free(buddy)) {
            cache->orders[slab->order].stats.total -= slab->size;
            do {
                    slab = slab_merge(cache, slab, buddy);
                    buddy = slab_buddy(cache, slab);
            } while (buddy && buddy->order == slab->order &&
                     slab_is_free(buddy));
            cache->orders[slab->order].stats.total += slab->size;
        }
        slab_poison(slab);
        if (slab->order == cache->order_max &&
        !rlist_empty(&cache->orders[slab->order].slabs)) {
            /*
                * Largest slab should be returned to arena, but we do so
                * only if the slab cache has at least one slab of that size
                * in order to avoid oscillations.
                */
            assert(slab->size == cache->arena->slab_size);
            slab_list_del(&cache->allocated, slab, next_in_cache);
            cache->orders[slab->order].stats.total -= slab->size;
            slab_unmap(cache->arena, slab);
        } else {
            /* Put the slab to the cache */
            rlist_add_entry(&cache->orders[slab->order].slabs, slab,
                            next_in_list);
        }
   }

..  _mempool:

Mempool
-------

Mempool is used to allocate small objects through splitting **slab cache
ordered slabs** into pieces of the equal size. This is extremely helpful
for vast amounts of fast allocations. On creation we need to specify
object size for a **memory pool**. Thus, the possible object count is
calculated, and we get the **memory pool** with ``int64_t`` aligned
**offset** ready for allocations. **Mempool** works with **slab** wrap
called **mslab**, which is needed to cut it in pieces.

..  _mslab-mempool-definitions:

MSlab & mempool definitions
~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    /** mslab - a standard slab formatted to store objects of equal size. */
    struct mslab {
        struct slab slab;
        /* Head of the list of used but freed objects */
        void *free_list;
        /** Offset of an object that has never been allocated in mslab */
        uint32_t free_offset;
        /** Number of available slots in the slab. */
        uint32_t nfree;
        /** Used if this slab is a member of hot_slabs tree. */
        rb_node(struct mslab) next_in_hot;
        /** Next slab in stagged slabs list in mempool object */
        struct rlist next_in_cold;
        /** Set if this slab is a member of hot_slabs tree */
        bool in_hot_slabs;
    };

    /** A memory pool. */
    struct mempool
    {
        /**
        * A link in delayed free list of pools. Must be the first
        * member in the struct.
        * @sa smfree_delayed().
        */
        struct lifo link;
        /** List of pointers for delayed free. */
        struct lifo delayed;
        /** The source of empty slabs. */
        struct slab_cache *cache;
        /** All slabs. */
        struct slab_list slabs;
        /**
        * Slabs with some amount of free space available are put
        * into this red-black tree, which is sorted by slab
        * address. A (partially) free slab with the smallest
        * address is chosen for allocation. This reduces internal
        * memory fragmentation across many slabs.
        */
        mslab_tree_t hot_slabs;
        /** Cached leftmost node of hot_slabs tree. */
        struct mslab *first_hot_slab;
        /**
        * Slabs with a little of free items count, staged to
        * be added to hot_slabs tree. Are  used in case the
        * tree is empty or the allocator runs out of memory.
        */
        struct rlist cold_slabs;
        /**
        * A completely empty slab which is not freed only to
        * avoid the overhead of slab_cache oscillation around
        * a single element allocation.
        */
        struct mslab *spare;
        /**
        * The size of an individual object. All objects
        * allocated on the pool have the same size.
        */
        uint32_t objsize;
        /**
        * Mempool slabs are ordered (@sa slab_cache.h for
        * definition of "ordered"). The order is calculated
        * when the pool is initialized or is set explicitly.
        * The latter is necessary for 'small' allocator,
        * which needs to quickly find mempool containing
        * an allocated object when the object is freed.
        */
        uint8_t slab_order;
        /** How many objects can fit in a slab. */
        uint32_t objcount;
        /** Offset from beginning of slab to the first object */
        uint32_t offset;
        /** Address mask to translate ptr to slab */
        intptr_t slab_ptr_mask;
    };

..  _mempool-methods:

Mempool methods
~~~~~~~~~~~~~~~

Creating **mempool** and **mslab** (from **slab**) is quite trivial,
though still worth looking at.

..  code:: c

    /**
     * Initialize a mempool. Tell the pool the size of objects
     * it will contain.
     *
     * objsize must be >= sizeof(mbitmap_t)
     * If allocated objects must be aligned, then objsize must
     * be aligned. The start of free area in a slab is always
     * uint64_t aligned.
     *
     * @sa mempool_destroy()
     */
    static inline void
    mempool_create(struct mempool *pool, struct slab_cache *cache,
                   uint32_t objsize)
    {
        size_t overhead = (objsize > sizeof(struct mslab) ?
                           objsize : sizeof(struct mslab));
        size_t slab_size = (size_t) (overhead / OVERHEAD_RATIO);
        if (slab_size > cache->arena->slab_size)
                slab_size = cache->arena->slab_size;
        /*
        * Calculate the amount of usable space in a slab.
        * @note: this asserts that slab_size_min is less than
        * SLAB_ORDER_MAX.
        */
        uint8_t order = slab_order(cache, slab_size);
        assert(order <= cache->order_max);
        return mempool_create_with_order(pool, cache, objsize, order);
    }

    void
    mempool_create_with_order(struct mempool *pool, struct slab_cache *cache,
                              uint32_t objsize, uint8_t order)
    {
        assert(order <= cache->order_max);
        lifo_init(&pool->link);
        lifo_init(&pool->delayed);
        pool->cache = cache;
        slab_list_create(&pool->slabs);
        mslab_tree_new(&pool->hot_slabs);
        pool->first_hot_slab = NULL;
        rlist_create(&pool->cold_slabs);
        pool->spare = NULL;
        pool->objsize = objsize;
        pool->slab_order = order;
        /* Total size of slab */
        uint32_t slab_size = slab_order_size(pool->cache, pool->slab_order);
        /* Calculate how many objects will actually fit in a slab. */
        pool->objcount = (slab_size - mslab_sizeof()) / objsize;
        assert(pool->objcount);
        pool->offset = slab_size - pool->objcount * pool->objsize;
        pool->slab_ptr_mask = ~(slab_order_size(cache, order) - 1);
    }

    static inline void
    mslab_create(struct mslab *slab, struct mempool *pool)
    {
        slab->nfree = pool->objcount;
        slab->free_offset = pool->offset;
        slab->free_list = NULL;
        slab->in_hot_slabs = false;
        rlist_create(&slab->next_in_cold);
    }

..  _mempool_alloc:

Most importantly, mempool allows to allocate memory for a small object.
This allocation is the most frequent in **tarantool**. Memory piece is
being given solely based on the provided mempool. The first problem is
to find a suitable **slab**. If there is an appropriate slab, already
acquired from **slab cache** and still available, it will be used.
Otherwise, we might get totally free **cached slab** not yet returned to
the arena. In case there are no such slabs, we will try to perform
possibly heavier operation, trying to get a slab from the **slab cache**
through its :ref:`slab_get_with_order <slab_get_with_order>` method. As
the last resort we are trying to get a **cold slab**, the type of
**slab** which is mostly filled, but has one freed block. This **slab**
is being added to **hot** list, and then, finally, we are acquiring
direct pointer through ``mslab_alloc``, using **mslab** offset, shifting
as we allocate new pieces.

..  code:: c

    void *
    mempool_alloc(struct mempool *pool)
    {
        struct mslab *slab = pool->first_hot_slab;
        if (slab == NULL) {
        if (pool->spare) {
            slab = pool->spare;
            pool->spare = NULL;

        } else if ((slab = (struct mslab *)
                    slab_get_with_order(pool->cache,
                                        pool->slab_order))) {
            mslab_create(slab, pool);
            slab_list_add(&pool->slabs, &slab->slab, next_in_list);
        } else if (! rlist_empty(&pool->cold_slabs)) {
            slab = rlist_shift_entry(&pool->cold_slabs, struct mslab,
                                         next_in_cold);
        } else {
            return NULL;
        }
        assert(slab->in_hot_slabs == false);
        mslab_tree_insert(&pool->hot_slabs, slab);
        slab->in_hot_slabs = true;
        pool->first_hot_slab = slab;
        }
        pool->slabs.stats.used += pool->objsize;
        void *ptr = mslab_alloc(pool, slab);
        assert(ptr != NULL);
        VALGRIND_MALLOCLIKE_BLOCK(ptr, pool->objsize, 0, 0);
        return ptr;
    }

    void *
    mslab_alloc(struct mempool *pool, struct mslab *slab)
    {
        assert(slab->nfree);
        void *result;
        if (slab->free_list) {
            /* Recycle an object from the garbage pool. */
            result = slab->free_list;
            slab->free_list = *(void **)slab->free_list;
        } else {
            /* Use an object from the "untouched" area of the slab. */
            result = (char *)slab + slab->free_offset;
            slab->free_offset += pool->objsize;
        }

        /* If the slab is full, remove it from the rb tree. */
        if (--slab->nfree == 0) {
            if (slab == pool->first_hot_slab) {
                    pool->first_hot_slab = mslab_tree_next(&pool->hot_slabs,
                                                            slab);
            }
            mslab_tree_remove(&pool->hot_slabs, slab);
            slab->in_hot_slabs = false;
        }
        return result;
    }

..  _mslab_free:

There is a possibility to free memory from each allocated small object.
Each **mslab** has **free_list** -- list of emptied chunks. It is being
updated according to the new emptied area pointer. Then we decide where
to place processed **mslab**: it will be either **hot** one, **cold**
one, or **spare** one, depending on the new free chunks amount.

..  code:: c

    void
    mslab_free(struct mempool *pool, struct mslab *slab, void *ptr)
    {
        /* put object to garbage list */
        *(void **)ptr = slab->free_list;
        slab->free_list = ptr;
        VALGRIND_FREELIKE_BLOCK(ptr, 0);
        VALGRIND_MAKE_MEM_DEFINED(ptr, sizeof(void *));

        slab->nfree++;

        if (slab->in_hot_slabs == false &&
        slab->nfree >= (pool->objcount >> MAX_COLD_FRACTION_LB)) {
            /**
                * Add this slab to the rbtree which contains
                * sufficiently fragmented slabs.
                */
            rlist_del_entry(slab, next_in_cold);
            mslab_tree_insert(&pool->hot_slabs, slab);
            slab->in_hot_slabs = true;
            /*
                * Update first_hot_slab pointer if the newly
                * added tree node is the leftmost.
                */
            if (pool->first_hot_slab == NULL ||
                mslab_cmp(pool->first_hot_slab, slab) == 1) {

                    pool->first_hot_slab = slab;
            }
        } else if (slab->nfree == 1) {
            rlist_add_entry(&pool->cold_slabs, slab, next_in_cold);
        } else if (slab->nfree == pool->objcount) {
            /** Free the slab. */
            if (slab == pool->first_hot_slab) {
                    pool->first_hot_slab =
                            mslab_tree_next(&pool->hot_slabs, slab);
            }
            mslab_tree_remove(&pool->hot_slabs, slab);
            slab->in_hot_slabs = false;
            if (pool->spare > slab) {
                    slab_list_del(&pool->slabs, &pool->spare->slab,
                                  next_in_list);
                    slab_put_with_order(pool->cache, &pool->spare->slab);
                    pool->spare = slab;
                } else if (pool->spare) {
                     slab_list_del(&pool->slabs, &slab->slab,
                                   next_in_list);
                     slab_put_with_order(pool->cache, &slab->slab);
                } else {
                     pool->spare = slab;
                }
        }
    }

..  _small:

Small
-----

On the top of **allocators**, listed above, we have one more -- the one
actually used to allocate tuples. Basically, here we are trying to find
a suitable **mempool** to perform :ref:`mempool_alloc <mempool_alloc>` on
it. Small system introduces **stepped** and **factored** pools to fit
different **allocation** sizes. There is an array of **stepped** pools,
which are intended to contain relatively small objects. Their
**objsize**\ s (struct :ref:`mempool <mempool>` field) are under about 500
bytes and differ by predefined ``STEP_SIZE``. There are also **factored**
pools, which are intended to be used for bigger objects. They are called
**factored** as far as each of them can contain objects from size ``sz``
to size ``alloc_factor * sz``, where ``alloc_factor`` may be adjusted by
the user. **Factored** pools are only being created for a given size if
needed, and their amount is limited.

..  _factor-pool-small-allocator-definitions:

Factor pool & small allocator definitions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    struct factor_pool
    {
        /** rb_tree entry */
        rb_node(struct factor_pool) node;
        /** the pool itself. */
        struct mempool pool;
        /**
        * Objects starting from this size and up to
        * pool->objsize are stored in this factored
        * pool.
        */
        size_t objsize_min;
        /** next free factor pool in the cache. */
        struct factor_pool *next;
    };

    /** A slab allocator for a wide range of object sizes. */
    struct small_alloc {
        struct slab_cache *cache;
        uint32_t step_pool_objsize_max;
        /**
        * All slabs in all pools must be of the same order,
        * otherwise small_free() has no way to derive from
        * pointer its slab and then the pool.
        */
        /**
        * An array of "stepped" pools, pool->objsize of adjacent
        * pools differ by a fixed size (step).
        */
        struct mempool step_pools[STEP_POOL_MAX];
        /** A cache for nodes in the factor_pools tree. */
        struct factor_pool factor_pool_cache[FACTOR_POOL_MAX];
        /** First free element in factor_pool_cache. */
        struct factor_pool *factor_pool_next;
        /**
        * A red-black tree with "factored" pools, i.e.
        * each pool differs from its neighbor by a factor.
        */
        factor_tree_t factor_pools;
        /**
        * List of mempool which objects to be freed if delayed free mode.
        */
        struct lifo delayed;
        /**
        * List of large allocations by malloc() to be freed in delayed mode.
        */
        struct lifo delayed_large;
        /**
        * The factor used for factored pools. Must be > 1.
        * Is provided during initialization.
        */
        float factor;
        uint32_t objsize_max;
        /**
        * Free mode.
        */
        enum small_free_mode free_mode;
        /**
        * Object size of step pool 0 divided by STEP_SIZE, to
        * quickly find the right stepped pool given object size.
        */
        uint32_t step_pool0_step_count;
    };

..  _small-methods:

Small methods
~~~~~~~~~~~~~

Small allocator is created with **slab cache**, which is the allocations
source for it. There is also being prepared **factored pools** tree,
some sane checks for **alignments** and **alloc_factor** are being
performed.

..  code:: c

    /** Initialize the small allocator. */
    void
    small_alloc_create(struct small_alloc *alloc, struct slab_cache *cache,
                       uint32_t objsize_min, float alloc_factor)
    {
        alloc->cache = cache;
        /* Align sizes. */
        objsize_min = small_align(objsize_min, STEP_SIZE);
        alloc->step_pool0_step_count = (objsize_min - 1) >> STEP_SIZE_LB;
        /* Make sure at least 4 largest objects can fit in a slab. */
        alloc->objsize_max =
            mempool_objsize_max(slab_order_size(cache, cache->order_max));

        if (!(alloc->objsize_max > objsize_min + STEP_POOL_MAX * STEP_SIZE)) {
            fprintf(stderr, "Can't create small alloc, small "
                    "object min size should not be greater than %u\n",
                    alloc->objsize_max - (STEP_POOL_MAX + 1) * STEP_SIZE);
            abort();
        }

        struct mempool *step_pool;
        for (step_pool = alloc->step_pools;
            step_pool < alloc->step_pools + STEP_POOL_MAX;
            step_pool++) {
            mempool_create(step_pool, alloc->cache, objsize_min);
            objsize_min += STEP_SIZE;
        }
        alloc->step_pool_objsize_max = (step_pool - 1)->objsize;
        if (alloc_factor > 2.0)
            alloc_factor = 2.0;
        /*
        * Correct the user-supplied alloc_factor to ensure that
        * it actually produces growing object sizes.
        */
        if (alloc->step_pool_objsize_max * alloc_factor <
        alloc->step_pool_objsize_max + STEP_SIZE) {

            alloc_factor =
                    (alloc->step_pool_objsize_max + STEP_SIZE + 0.5)/
                    alloc->step_pool_objsize_max;
        }
        alloc->factor = alloc_factor;

        /* Initialize the factored pool cache. */
        struct factor_pool *factor_pool = alloc->factor_pool_cache;
        do {
            factor_pool->next = factor_pool + 1;
            factor_pool++;
        } while (factor_pool !=
                alloc->factor_pool_cache + FACTOR_POOL_MAX - 1);
        factor_pool->next = NULL;
        alloc->factor_pool_next = alloc->factor_pool_cache;
        factor_tree_new(&alloc->factor_pools);
        (void) factor_pool_create(alloc, NULL, alloc->objsize_max);

        lifo_init(&alloc->delayed);
        lifo_init(&alloc->delayed_large);
        alloc->free_mode = SMALL_FREE;
    }

..  _smalloc:

Most importantly, **small allocator** allows us to allocate memory for
an object of a given size. Here we start with **garbage collection**.
**Factored pools** are being created when needed on allocation. First we
start with garbage collection. This means we actually deallocate
previously pushed to queues normal and large allocations, using
``mempool_free`` with :ref:`mslab_free <mslab_free>` under the hood and
:ref:`slab_put_large <slab_put_large>` respectively. Next thing to do is
to decide if we can use **stepped pool** for allocation, or we need to
use **factored pool** based on the given object size. To calculate which
**stepped pool** is needed, we divide size by ``STEP_SIZE`` using bit
shift and subtract predefined the smallest possible size (already
divided by ``STEP_SIZE``), as far as sizes don't start from zero. Thus, we
either get the needed pool and may proceed to
:ref:`mempool_alloc <mempool_alloc>` or understand that size is too big
for **stepped pools**. Therefore, we will try to find a big enough
**factored pool**. If there is nothing big enough for given **size**, we
will try to use :ref:`slab_get_large <slab_get_large>` directly.
Otherwise, we will either proceed to :ref:`mempool_alloc <mempool_alloc>`
or try creating smaller **factored pool** (if relevant). If we are not
succeeding with a smaller **factored pool**, we will need to use an
imperfect one. Anyway, finally, we are coming with our pool to
:ref:`mempool_alloc <mempool_alloc>` (except the case where we had to try
:ref:`slab_get_large <slab_get_large>` instead).

..  code:: c

    /**
     * Allocate a small object.
     *
     * Find or create a mempool instance of the right size,
     * and allocate the object on the pool.
     *
     * If object is small enough to fit a stepped pool,
     * finding the right pool for it is just a matter of bit
     * shifts. Otherwise, look up a pool in the red-black
     * factored pool tree.
     *
     * @retval ptr success
     * @retval NULL out of memory
     */
    void *
    smalloc(struct small_alloc *alloc, size_t size)
    {
        small_collect_garbage(alloc);

        struct mempool *pool;
        int idx = (size - 1) >> STEP_SIZE_LB;
        idx = (idx > (int) alloc->step_pool0_step_count) ? idx - alloc->step_pool0_step_count : 0;
        if (idx < STEP_POOL_MAX) {
            /* Allocate in a stepped pool. */
            pool = &alloc->step_pools[idx];
            assert(size <= pool->objsize &&
                   (size + STEP_SIZE > pool->objsize || idx == 0));
        } else {
            struct factor_pool pattern;
            pattern.pool.objsize = size;
            struct factor_pool *upper_bound =
                    factor_tree_nsearch(&alloc->factor_pools, &pattern);
            if (upper_bound == NULL) {
                    /* Object is too large, fallback to slab_cache */
                    struct slab *slab = slab_get_large(alloc->cache, size);
                    if (slab == NULL)
                            return NULL;
                    return slab_data(slab);
            }

            if (size < upper_bound->objsize_min)
                    upper_bound = factor_pool_create(alloc, upper_bound,
                                                     size);
            pool = &upper_bound->pool;
        }
        assert(size <= pool->objsize);
        return mempool_alloc(pool);
    }

..  _interim-conclusion:

Interim conclusion
------------------

By now we got partly familiar with the hierarchy of memory managers in
**tarantool**. Described subsystems are explicitly organized, while
**region** allocator and **matras** are standing a bit on the side.
Basically, we have a number of functions, providing service on their
level as following:

| .\ :ref:`slab_map <slab_map>`
| ..\ :ref:`slab_get_with_order <slab_get_with_order>`
| ...\ :ref:`mempool_alloc <mempool_alloc>`
| ....\ :ref:`smalloc <smalloc>`
| Or, alternatively
| .\ :ref:`slab_get_large <slab_get_large>`
| ..\ :ref:`smalloc <smalloc>`

While :ref:`smalloc <smalloc>` is only used for tuple allocation,
:ref:`mempool_alloc <mempool_alloc>` is widely used for internal needs. It
is used by **curl**, **http** module, **iproto**, **fibers** and other
subsystems. Alongside with many other **allocations**, the most
interesting one is ``memtx_index_extent_alloc`` function, used as the
allocation function for **memtx index** needs by **matras**, which works
in pair with ``memtx_index_extent_reserve``. ``memtx_index_extent_reserve``
is being called when we are going to **build** or **rebuild index** to
make sure that we have enough **reserved extents**. Otherwise,
``memtx_index_extent_reserve`` tries to allocate **extents** until we get
the given number and aborts if it can't be done. This allows us to stick
to consistency and abort the operation before it is too late.

..  _memtx_index_extent_alloc:

..  code:: c

    /**
     * Allocate a block of size MEMTX_EXTENT_SIZE for memtx index
     */
    void *
    memtx_index_extent_alloc(void *ctx)
    {
        struct memtx_engine *memtx = (struct memtx_engine *)ctx;
        if (memtx->reserved_extents) {
            assert(memtx->num_reserved_extents > 0);
            memtx->num_reserved_extents--;
            void *result = memtx->reserved_extents;
            memtx->reserved_extents = *(void **)memtx->reserved_extents;
            return result;
        }
        ERROR_INJECT(ERRINJ_INDEX_ALLOC, {
            /* same error as in mempool_alloc */
            diag_set(OutOfMemory, MEMTX_EXTENT_SIZE,
                     "mempool", "new slab");
            return NULL;
        });
        void *ret;
        while ((ret = mempool_alloc(&memtx->index_extent_pool)) == NULL) {
            bool stop;
            memtx_engine_run_gc(memtx, &stop);
            if (stop)
                    break;
        }
        if (ret == NULL)
            diag_set(OutOfMemory, MEMTX_EXTENT_SIZE,
                     "mempool", "new slab");
        return ret;
    }

..  _memtx_index_extent_reserve:

..  code:: c

    /**
     * Reserve num extents in pool.
     * Ensure that next num extent_alloc will succeed w/o an error
     */
    int
    memtx_index_extent_reserve(struct memtx_engine *memtx, int num)
    {
        ERROR_INJECT(ERRINJ_INDEX_ALLOC, {
            /* same error as in mempool_alloc */
            diag_set(OutOfMemory, MEMTX_EXTENT_SIZE,
                     "mempool", "new slab");
            return -1;
        });
        struct mempool *pool = &memtx->index_extent_pool;
        while (memtx->num_reserved_extents < num) {
            void *ext;
            while ((ext = mempool_alloc(pool)) == NULL) {
                    bool stop;
                    memtx_engine_run_gc(memtx, &stop);
                    if (stop)
                            break;
            }
            if (ext == NULL) {
                    diag_set(OutOfMemory, MEMTX_EXTENT_SIZE,
                             "mempool", "new slab");
                    return -1;
            }
            *(void **)ext = memtx->reserved_extents;
            memtx->reserved_extents = ext;
            memtx->num_reserved_extents++;
        }
        return 0;
    }

:ref:`memtx_index_extent_reserve <memtx_index_extent_reserve>` is mostly
used within ``memtx_space_replace_all_keys``, which basically handles all
**updates, replaces** and **deletes**, which makes it very frequently
called function. Here is the interesting fact: in case of **update** or
**replace** we assume that we need **16 reserved extents** to guarantee
success, while for **delete** operation we only need **8 reserved
extents**. The interesting thing here is that we don't want
:ref:`memtx_index_extent_reserve <memtx_index_extent_reserve>` to fail on
**delete**. The idea is that even when we don't have 16 reserved
extents, we will have at least 8 reserved extents and **delete**
operation won't fail. However, there are situations, when reserved
extents number might be 0, when user starts to **delete**, for example,
in case we are **creating index** before deletion and it fails. Though
deletion fail is still hard to reproduce, although it seems to be
possible.

Matras
------

Matras is a **memory address translation allocator**, providing aligned
identifiable blocks of specified size. It is designed to maintain index
with versioning and consistent read views. It is organized as a 3-level
tree, where level 1 is an array of pointers to level 2 extents, level 2
extent is an array of pointers to level 3 extents, and level 3 extent is
an array of blocks. Block id so far consists of 3 parts (11, 11 and 10
bits), respectively pointing at level 1, level 2 and level 3 extents.

Matras definition
~~~~~~~~~~~~~~~~~

Matras uses allocation func determined on creation, which actually is
:ref:`mempool_alloc <mempool_alloc>` wrapped into
:ref:`memtx_index_extent_alloc <memtx_index_extent_alloc>`.

..  code:: c

    /**
     * sruct matras_view represents appropriate mapping between
     * block ID and it's pointer.
     * matras structure has one main read/write view, and a number
     * of user created read-only views.
     */
    struct matras_view {
        /* root extent of the view */
        void *root;
        /* block count in the view */
        matras_id_t block_count;
        /* all views are linked into doubly linked list */
        struct matras_view *prev_view, *next_view;
    };

    /**
     * matras - memory allocator of blocks of equal
     * size with support of address translation.
     */
    struct matras {
        /* Main read/write view of the matras */
        struct matras_view head;
        /* Block size (N) */
        matras_id_t block_size;
        /* Extent size (M) */
        matras_id_t extent_size;
        /* Numberof allocated extents */
        matras_id_t extent_count;
        /* binary logarithm  of maximum possible created blocks count */
        matras_id_t log2_capacity;
        /* See "Shifts and masks explanation" below  */
        matras_id_t shift1, shift2;
        /* See "Shifts and masks explanation" below  */
        matras_id_t mask1, mask2;
        /* External extent allocator */
        matras_alloc_func alloc_func;
        /* External extent deallocator */
        matras_free_func free_func;
        /* Argument passed to extent allocator */
        void *alloc_ctx;
    };

Matras methods
~~~~~~~~~~~~~~

Matras creation is quite self-explanatory. Shifts and masks are used to
determine ids for level 1, 2 & 3 extents in the following way: *N1 = ID
>> shift1*, *N2 = (ID & mask1) >> shift2*, *N3 = ID & mask2*.

..  code:: c

    /**
     * Initialize an empty instance of pointer translating
     * block allocator. Does not allocate memory.
     */
    void
    matras_create(struct matras *m, matras_id_t extent_size, matras_id_t block_size,
                  matras_alloc_func alloc_func, matras_free_func free_func,
                  void *alloc_ctx)
    {
        /*extent_size must be power of 2 */
        assert((extent_size & (extent_size - 1)) == 0);
        /*block_size must be power of 2 */
        assert((block_size & (block_size - 1)) == 0);
        /*block must be not greater than the extent*/
        assert(block_size <= extent_size);
        /*extent must be able to store at least two records*/
        assert(extent_size > sizeof(void *));

        m->head.block_count = 0;
        m->head.prev_view = 0;
        m->head.next_view = 0;
        m->block_size = block_size;
        m->extent_size = extent_size;
        m->extent_count = 0;
        m->alloc_func = alloc_func;
        m->free_func = free_func;
        m->alloc_ctx = alloc_ctx;

        matras_id_t log1 = matras_log2(extent_size);
        matras_id_t log2 = matras_log2(block_size);
        matras_id_t log3 = matras_log2(sizeof(void *));
        m->log2_capacity = log1 * 3 - log2 - log3 * 2;
        m->shift1 = log1 * 2 - log2 - log3;
        m->shift2 = log1 - log2;
        m->mask1 = (((matras_id_t)1) << m->shift1) - ((matras_id_t)1);
        m->mask2 = (((matras_id_t)1) << m->shift2) - ((matras_id_t)1);
    }

Allocation using matras requires relatively complicated calculations due
to 3-level extents tree.

..  code:: c

    /**
     * Allocate a new block. Return both, block pointer and block
     * id.
     *
     * @retval NULL failed to allocate memory
     */
    void *
    matras_alloc(struct matras *m, matras_id_t *result_id)
    {
        assert(m->head.block_count == 0 ||
            matras_log2(m->head.block_count) < m->log2_capacity);

        /* Current block_count is the ID of new block */
        matras_id_t id = m->head.block_count;

        /* See "Shifts and masks explanation" for details */
        /* Additionally we determine if we must allocate extents.
        * Basically,
        * if n1 == 0 && n2 == 0 && n3 == 0, we must allocate root extent,
        * if n2 == 0 && n3 == 0, we must allocate second level extent,
        * if n3 == 0, we must allocate third level extent.
        * Optimization:
        * (n1 == 0 && n2 == 0 && n3 == 0) is identical to (id == 0)
        * (n2 == 0 && n3 == 0) is identical to (id & mask1 == 0)
        */
        matras_id_t extent1_available = id;
        matras_id_t n1 = id >> m->shift1;
        id &= m->mask1;
        matras_id_t extent2_available = id;
        matras_id_t n2 = id >> m->shift2;
        id &= m->mask2;
        matras_id_t extent3_available = id;
        matras_id_t n3 = id;

        void **extent1, **extent2;
        char *extent3;

        if (extent1_available) {
            extent1 = (void **)m->head.root;
        } else {
            extent1 = (void **)matras_alloc_extent(m);
            if (!extent1)
                    return 0;
            m->head.root = (void *)extent1;
        }

        if (extent2_available) {
            extent2 = (void **)extent1[n1];
        } else {
            extent2 = (void **)matras_alloc_extent(m);
            if (!extent2) {
                    if (!extent1_available) /* was created */
                            matras_free_extent(m, extent1);
                    return 0;
            }
            extent1[n1] = (void *)extent2;
        }

        if (extent3_available) {
            extent3 = (char *)extent2[n2];
        } else {
            extent3 = (char *)matras_alloc_extent(m);
            if (!extent3) {
                    if (!extent1_available) /* was created */
                            matras_free_extent(m, extent1);
                    if (!extent2_available) /* was created */
                            matras_free_extent(m, extent2);
                    return 0;
            }
            extent2[n2] = (void *)extent3;
        }

        *result_id = m->head.block_count++;
        return (void *)(extent3 + n3 * m->block_size);
    }
