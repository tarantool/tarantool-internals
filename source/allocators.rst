.. vim: ts=4 sw=4 et

Memory management
=================

Introduction
------------

Tarantool has a number of memory managers used for different purposes.
They include **slab_arena**, **slab_cache** system, **mempool**,
**small** allocator, **region** allocator and **matras**, which are
organized hierarchically. To understand what it really means, you need
to pass through the following guide.

At the beginning of the main() function memory is allocated with creating
**arena** (*memory_init()*):

..  code:: c

    /* main.cc */
    int main(int argc, char **argv)
    {
        ...
        /* lib/core/memory.c */
        memory_init();
            /* memory_init() code */
            static struct quota runtime_quota;
            const size_t SLAB_SIZE = 4 * 1024 * 1024;
            /* default quota initialization */
            quota_init(&runtime_quota, QUOTA_MAX);

            /* No limit on the runtime memory. */
            slab_arena_create(&runtime, &runtime_quota, 0,
                      SLAB_SIZE, SLAB_ARENA_PRIVATE);
        ...
        tarantool_free();
            /* tarantool_free() code */
            /* lib/core/memory.c */
            memory_free();
                /* memory_free() code */
                #if 0
                    slab_arena_destroy(&runtime);
                #endif
    }

*memory_init* and *memory_free* are used to create and free arena for
runtime slabs. This is where additional info is stored (e.g. indexes,
connection information). It may consume up to 20% of data arena size.

Note, that the code in *memory_free()* is never executed. Deallocating
never happens here, as register stack pointer is pointing to the memory
we are trying to unmap. There's a problem with a number of fibers, which
still refer to this memory.

Creating of arena for the real data is done on box configuration.
This is the memory where all spaces are stored.

.. code:: c

    /** main.cc */
    void load_cfg(void)
    {
        ...
        /* box/box.cc */
        box_cfg()
            /* box_cfg() code */
            box_storage_init();
                /* box_storage_init() code */
                engine_init();
                    /* engine_init() code */
                    /* src/box/memtx_engine.cc */
                    memtx = memtx_engine_new_xc(...)
                        /* memtx_engine_new() code */
                        tuple_arena_create(...)
                            slab_arena_create(...)
                            slab_cache_create(...);
                    ...
                    vinyl = vinyl_engine_new_xc(...)
                        ...
                    ...
                ...
            ...
        ...
    }

So, let's start from the **arena**, as far as it is the root of the memory
hierarchy.

..  _arena:

Arena
-----

Arena is responsible for allocating relatively large aligned memory blocks
(called **slabs**) of the given size. It also can preallocate quite a lot of
memory, from which it creates slabs. The maximum size of arena is limited
with **quota**.

.. code-block:: text

    +-----------------------------------------------------------+
    | Arena                                                     |
    |-----------------------------------------------------------|
    |                         Cache area                        |
    | +-------------+      +-------------+      +-------------+ |
    | |             |      |             |      |             | |
    | | Cached slab | ---> | Cached slab | ---> | Cached slab | |
    | |             |      |             |      |             | |
    | +-------------+      +-------------+      +-------------+ |
    |-----------------------------------------------------------|
    |                        Used memory                        |
    | +-------------+      +-------------+      +-------------+ |
    | |             |      |             |      |             | |
    | | In-use slab |      | In-use slab |      | In use slab | |
    | |             |      |             |      |             | |
    | +-------------+      +-------------+      +-------------+ |
    +-----------------------------------------------------------+

*memtx_memory* or *vinyl_memory* controls, how much memory is preallocated
in data arena. The same value is used for arena's **quota**. Speaking of
runtime arena, no memory is preallocated, **quota** is not limited at all.

..  _arena-definition:

Arena definition
~~~~~~~~~~~~~~~~

..  code:: c

    /* lib/small/small/slab_arena.c */
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
memory. It uses mmap for allocation. The size of allocated memory is
aligned with the integer number of slabs.

..  code:: c

    /* lib/small/small/slab_arena.c */
    int slab_arena_create(struct slab_arena *arena, struct quota *quota,
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

*flags** can have the following values:

..  code:: c

    /* lib/small/include/small/slab_arena.h */
    enum {
        /* mmap() flags */
        SLAB_ARENA_PRIVATE    = SLAB_ARENA_FLAG(1 << 0),
        SLAB_ARENA_SHARED     = SLAB_ARENA_FLAG(1 << 1),

        /* madvise() flags */
        SLAB_ARENA_DONTDUMP   = SLAB_ARENA_FLAG(1 << 2)
    };

First two of them are mapped to *MAP_PRIVATE | MAP_ANONYMOUS* and
*MAP_SHARED | MAP_ANONYMOUS* respectively and used for *mmap()* function
(see *man mmap*). The last one is for *madvise* system call
(see *man madvise*). It says to kernel to exclude from a core dump some
memory pages and can be controlled with *strip_core* box.cfg option.

..  _slab_map:

Most importantly, arena allows us to map a **slab**. First, we check the
list of returned **slabs**, called **arena** cache (not **slab cache**),
which contains previously used and now emptied slabs. If there are no
such **slabs**, we confirm that **quota** limit is fulfilled and then
either take **slab** from the **preallocated** area or allocate it.

..  code:: c

    /* lib/small/small/slab_arena.c */
    void *slab_map(struct slab_arena *arena)
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
back faster next time. If at some point of time some number of slabs are
allocated, then in the future oll of them will be available for reuse,
mmemory is not deallocated in ``slab_unmap``.

..  code:: c

    /* lib/small/small/slab_arena.c */
    void slab_unmap(struct slab_arena *arena, void *ptr)
    {
        if (ptr == NULL)
            return;

        lf_lifo_push(&arena->cache, ptr);
        VALGRIND_MAKE_MEM_NOACCESS(ptr, arena->slab_size);
        VALGRIND_MAKE_MEM_DEFINED(lf_lifo(ptr), sizeof(struct lf_lifo));
    }

However, arena provides pretty low-level interfaces and is not used
on its own. Slab cache is used istead. So, let's look at how it works.

Note, that slab cache has nothing in common with the cached slabs inside
arena itself! In arena it's just a list of slabs, which was returned to
arena. Slab cache on its own is an algorithm of memory management.

..  _slab-cache:

Slab cache
----------

Slab cache allows us to get a piece of **arena slab** with the size
close to needed. It implements a buddy system.

The buddy system is a memory allocation and management algorithm that
manages memory in power of two increments. Every memory block in this
system has an order, where the order is an integer ranging from 0 to
a specified upper limit. The size of a block of order n is proportional
to 2^n, so that the blocks are exactly twice the size of blocks that are
one order lower. Power-of-two block sizes make address computation simple,
because all buddies are aligned on memory address boundaries that are
powers of two. When a larger block is split, it is divided into two smaller
blocks, and each smaller block becomes a unique buddy to the other. A split
block can only be merged with its unique buddy block, which then reforms the
larger block they were split from. It helps to avoid fragmentation of a data.

Assume our **arena slab** smallest possible block is 64 bytes in size and
its maximum order is 4. So the size of arena is 2^2 * 64 bytes = 256 bytes.

    1. Initial state
    2. User A. Slab of size 64 is requested, order 0:
        1. No order 0 blocks are available, so an order 2 block is split,
           creating two order 1 blocks (128 bytes each).
        2. Still no order 0 blocks available, so the first order 1 block
           is split, creating two order 0 blocks.
        3. Now an order 0 block is available, so it is allocated.
    3. User B. Slab of size 128 is requested, order 1. An order 1 block is
       available, so it is allocated to B.
    4. User A releases its memory:
        1. One order 0 block is freed.
        2. Since the buddy block of the newly freed block is also free, the
           two are merged into one order 1 block
    5. User B releases its memory:
        1. One order 1 block is freed.
        2. Since the buddy block of the newly freed block is also free, the
           two are merged into one order 2 block

.. code-block:: text

    +---------------------------------------+
    |  Step |  64B  |  64B  |  64B  |  64B  |
    |-------|-------------------------------|
    |   1   |              2^2              |
    |-------|-------------------------------|
    |  2.1  |       2^1     |      2^1      |
    |-------|-------------------------------|
    |  2.2  |  2^0  |  2^0  |      2^1      |
    |-------|-------------------------------|
    |  2.3  | A:2^0 |  2^0  |      2^1      |
    |-------|-------------------------------|
    |   3   | A:2^0 |  2^0  |     B:2^1     |
    |-------|-------------------------------|
    |  4.1  |  2^0  |  2^0  |     B:2^1     |
    |-------|-------------------------------|
    |  4.2  |       2^1     |     B:2^1     |
    |-------|-------------------------------|
    |  5.1  |       2^1     |      2^1      |
    |-------|-------------------------------|
    |  5.2  |              2^2              |
    +-------|-------------------------------+

Let's see how it is implemented in practice.

..  _slab-cache-definition:

Slab & slab cache definition
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    /* lib/small/include/small/slab_cache.h */
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

..  _slab_get_order:

We can find the order (nearest power of 2 size capable of containing
a chunk of the given size) with *slab_order* function:

..  code:: c

    /* lib/small/include/small/slab_cache.h */
    static inline uint8_t
    slab_order(struct slab_cache *cache, size_t size)
    {
        if (size <= cache->order0_size)
            return 0;
        if (size > cache->arena->slab_size)
            return cache->order_max + 1;

        return (uint8_t) (CHAR_BIT * sizeof(unsigned) -
                  __builtin_clz((unsigned) size - 1) -
                  cache->order0_size_lb);
    }

..  _slab_get_with_order:

We can acquire a **slab** of needed **order** with *slab_get_with_order*.
We first look through **orders** array of **slab** lists,
starting from the given **order**. We can use slabs of higher **order**.
In case nothing is found, we are trying to get a new **arena slab**
using previously described **arena** method :ref:`slab_map <slab_map>`. We
preprocess it and add it to the corresponding lists. Then we are
splitting the **slab** if the **order** doesn't match exactly.

.. code:: c

   /* lib/small/small/slab_cache.c */
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

    /* lib/small/small/slab_cache.c */
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

    /* lib/small/small/slab_cache.c */
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

..  _slab_put_with_order:

When the normal **slab** is being emptied, it is processed in a more
specific way, as mentioned above. We get its **buddy** (neighbour
**slab** of the same size, which complements current **slab** to the
**slab** of the next **order**). If **buddy** is not in use and is not
split into smaller parts, we **merge** them and get free **slab** of the
next **order**, thus avoiding fragmentation. If we get an **arena slab**
as the result, we return it to **arena** using its method
:ref`slab_unmap <slab_unmap>` in case there is already an **arena slab**
of the same size in **cache**. Otherwise, we leave it in **slab cache**
to avoid extra moves.

..  code:: c

    /* lib/small/small/slab_cache.c */
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

Slabs are still too big chunks of memory to work with, so we are moving
forward, to mempool.

Mempool is used to allocate small objects through splitting **slab cache
ordered slabs** into pieces of the equal size. In mempool all slabs have
the same order. This is extremely helpful for vast amounts of fast
allocations. On creation we need to specify object size for a **memory pool**.
Thus, the possible object count is calculated, and we get the **memory pool**
with ``int64_t`` aligned **offset** ready for allocations. **Mempool** works
with **slab** wrap called **mslab**, which is needed to cut it in pieces.

..  _mslab-mempool-definitions:

MSlab & mempool definitions
~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    /* lib/small/include/small/mempool.h */
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
        /** Pointer to mempool, the owner of this mslab */
        struct mempool *mempool;
    };

    /** A memory pool. */
    struct mempool
    {
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
        /**
         * Small allocator pool, the owner of this mempool in case
         * this mempool used as a part of small_alloc, otherwise
         * NULL
         */
        struct small_mempool *small_mempool;
    };

..  _mempool-methods:

Mempool methods
~~~~~~~~~~~~~~~

Creating **mempool** and **mslab** (from **slab**) is quite trivial,
though still worth looking at.

..  code:: c

    /* lib/small/small/mempool.c */
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

    /* lib/small/include/small/mempool.h */
    void
    mempool_create_with_order(struct mempool *pool, struct slab_cache *cache,
                              uint32_t objsize, uint8_t order)
    {
        assert(order <= cache->order_max);
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
        pool->small_mempool = NULL;
    }

    static inline void
    mslab_create(struct mslab *slab, struct mempool *pool)
    {
        slab->nfree = pool->objcount;
        slab->free_offset = pool->offset;
        slab->free_list = NULL;
        slab->in_hot_slabs = false;
        slab->mempool = pool;

        rlist_create(&slab->next_in_cold);
    }

..  _mempool_alloc:

Most importantly, mempool allows to allocate memory for a small object.
This allocation is the most frequent in **tarantool**. Memory piece is
being given solely based on the provided mempool. The first problem is
to find a suitable **slab**:

    1. If there is an appropriate slab, already acquired from
       **slab cache** and located at **hot_slabs**, where slabs with
       free space are stored, it will be used.
    2. Otherwise, we try to get totally empy **spare** slab, which was
       put there during *mslab_free*. *mslab_free* doesn't necessarily
       return slab to **slab_cache**: if there's no **spare** object
       during freeing, it's saved there to avoid oscillation. See
       :ref:`mslab_free<mslab_free>`.
    3. In case there are no such slabs, we will try to perform
       possibly heavier operation, trying to get a slab from the **slab cache**
       through its :ref:`slab_get_with_order <slab_get_with_order>` method.
    4. As the last resort we are trying to get a **cold slab**, the type of
       **slab** which is mostly filled, but has one freed block. This **slab**
       is being added to **hot** list, and then, finally, we are acquiring
       direct pointer through ``mslab_alloc``, using **mslab** offset, shifting
       as we allocate new pieces.

..  code:: c

    /* lib/small/small/mempool.c */
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
            /*
             * In case when pool objsize is not aligned sizeof(intptr_t)
             * boundary we can't use *(void **)slab->free_list construction,
             * because (void **)slab->free_list has not necessary aligment.
             * memcpy can work with misaligned address.
             */
            memcpy(&slab->free_list, (void **)slab->free_list,
                   sizeof(void *));
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

    /* lib/small/small/mempool.c */
    void
    mslab_free(struct mempool *pool, struct mslab *slab, void *ptr)
    {
        /* put object to garbage list */
        memcpy((void **)ptr, &slab->free_list, sizeof(void *));
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
                mempool_free_spare_slab(pool);
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
actually used to allocate tuples: small allocator. Basically, here we are
trying to find a suitable **mempool** to perform
:ref:`mempool_alloc <mempool_alloc>` on it.

There is one array which contained all pools in small allocator.
The array size limits the maximum possible number of mempools.
All mempools are created when creating an allocator. Their sizes and
count are calculated depending on alloc_factor and granularity (alignment
of objects in pools), using small_class (see :ref:`small_class <small_class>`
for more details). When requesting a memory allocation, we can find pool with
the most appropriate size in time O(1), using small_class.

..  _small-allocator-definitions:

Small allocator definitions
~~~~~~~~~~~~~~~~~~~~~~~~~~~

..  code:: c

    /* lib/small/include/small/small.h */
    struct small_mempool {
        /** the pool itself. */
        struct mempool pool;
        /**
         * Objects starting from this size and up to
         * pool->objsize are stored in this factored
         * pool.
         */
        size_t objsize_min;
        /** Small mempool group that this pool belongs to. */
        struct small_mempool_group *group;
        /**
         * Currently used pool for memory allocation. In case waste is
         * less than @waste_max of corresponding mempool_group, @used_pool
         * points to this structure itself.
         */
        struct small_mempool *used_pool;
        /**
         * Mask of appropriate pools. It is calculated once pool is created.
         * Values of mask for:
         * Pool 0: 0x0001 (0000 0000 0000 0001)
         * Pool 1: 0x0003 (0000 0000 0000 0011)
         * Pool 2: 0x0007 (0000 0000 0000 0111)
         * And so forth.
         */
        uint32_t appropriate_pool_mask;
        /**
         * Currently memory waste for a given mempool. Waste is calculated as
         * amount of excess memory spent for storing small object in pools
         * with large object size. For instance, if we store object with size
         * of 15 bytes in a 64-byte pool having inactive 32-byte pool, the loss
         * will be: 64 bytes - 32 bytes = 32 bytes.
         */
        size_t waste;
    };

    struct small_mempool_group {
        /** The first pool in the group. */
        struct small_mempool *first;
        /** The last pool in the group. */
        struct small_mempool *last;
        /**
         * Raised bit on position n means that the pool with index n can be
         * used for allocations. At the start only one pool (the last one)
         * is available. Also note that once pool become active.
         */
        uint32_t active_pool_mask;
        /**
         * Pre-calculated waste threshold reaching which small_mempool becomes
         * activated. It is equal to slab_order_size / 4.
         */
        size_t waste_max;
    };

    /** A slab allocator for a wide range of object sizes. */
    struct small_alloc {
        struct slab_cache *cache;
        /** Array of all small mempools of a given allocator */
        struct small_mempool small_mempool_cache[SMALL_MEMPOOL_MAX];
        /* small_mempool_cache array real size */
        uint32_t small_mempool_cache_size;
        /** Array of all small mempool groups of a given allocator */
        struct small_mempool_group small_mempool_groups[SMALL_MEMPOOL_MAX];
        /*
         * small_mempool_groups array real size. In the worst case each
         * group will contain only one pool, so the number of groups is
         * also limited by SMALL_MEMPOOL_MAX.
         */
        uint32_t small_mempool_groups_size;
        /**
         * The factor used for factored pools. Must be > 1.
         * Is provided during initialization.
         */
        float factor;
        /** Small class for this allocator */
        struct small_class small_class;
        uint32_t objsize_max;
    };

..  _small-methods:

Small methods
~~~~~~~~~~~~~

Small allocator is created with **slab cache**, which is the allocations
source for it. All mempools are divided into groups according to the order
of slabs, they contain, which is needed for O(1) search of required mempool.
One group cannot have more then 32 pools, so there might be several groups
with the same order.

..  code:: c

    /* lib/small/small/small.c */
    /** Initialize the small allocator. */
    void
    small_alloc_create(struct small_alloc *alloc, struct slab_cache *cache,
                       uint32_t objsize_min, float alloc_factor)
        uint32_t slab_order_cur = 0;
        size_t objsize = 0;
        struct small_mempool *cur_order_pool = &alloc->small_mempool_cache[0];
        alloc->small_mempool_groups_size = 0;
        bool first_iteration = true;

        for (alloc->small_mempool_cache_size = 0;
             objsize < alloc->objsize_max &&
             alloc->small_mempool_cache_size < SMALL_MEMPOOL_MAX;
             alloc->small_mempool_cache_size++) {
            size_t prevsize = objsize;
            uint32_t mempool_cache_size = alloc->small_mempool_cache_size;
            objsize = small_class_calc_size_by_offset(&alloc->small_class,
                                  mempool_cache_size);
            if (objsize > alloc->objsize_max)
                objsize = alloc->objsize_max;
            struct small_mempool *pool =
                &alloc->small_mempool_cache[mempool_cache_size];
            mempool_create(&pool->pool, alloc->cache, objsize);
            pool->pool.small_mempool = pool;
            pool->objsize_min = prevsize + 1;
            pool->group = NULL;
            pool->used_pool = NULL;
            pool->appropriate_pool_mask = 0;
            pool->waste = 0;

            if (first_iteration) {
                slab_order_cur = pool->pool.slab_order;
                first_iteration = false;
            }
            uint32_t slab_order_next = pool->pool.slab_order;
            /*
             * In the case when the size of slab changes, create one or
             * more mempool groups. The count of groups depends on the
             * mempools count with same slab size. There can be no more
             * than 32 pools in one group.
             */
            if (slab_order_next != slab_order_cur) {
                assert(cur_order_pool->pool.slab_ptr_mask ==
                       (pool - 1)->pool.slab_ptr_mask);
                slab_order_cur = slab_order_next;
                small_mempool_create_groups(alloc, cur_order_pool,
                                pool - 1);
                cur_order_pool = pool;
            }
            /*
             * Maximum object size for mempool allocation ==
             * alloc->objsize_max. If we have reached this size,
             * there will be no more pools - loop will be broken
             * at the next iteration. So we need to create the last
             * group of pools.
             */
            if (objsize == alloc->objsize_max) {
                assert(cur_order_pool->pool.slab_ptr_mask ==
                       pool->pool.slab_ptr_mask);
                small_mempool_create_groups(alloc, cur_order_pool,
                                pool);
            }
        }
        alloc->objsize_max = objsize;
    }

..  _smalloc:

Most importantly, **small allocator** allows us to allocate memory for
an object of a given size. With the help of :ref:`small_class <small_class>`
we find needed mempool and allocate the object on it. If there's no mempool
with enough memory, we fallback to the allocating of the large block from
**slab_cache**.

..  code:: c

    /* lib/small/small/small.c */
    void *
    smalloc(struct small_alloc *alloc, size_t size)
    {
        struct small_mempool *small_mempool = small_mempool_search(alloc, size);
        if (small_mempool == NULL) {
            /* Object is too large, fallback to slab_cache */
            struct slab *slab = slab_get_large(alloc->cache, size);
            if (slab == NULL)
                return NULL;
            return slab_data(slab);
        }
        struct mempool *pool = &small_mempool->used_pool->pool;
        assert(size <= pool->objsize);
        void *ptr = mempool_alloc(pool);
        if (ptr == NULL) {
            /*
             * In case we run out of memory let's try to deactivate some
             * pools and release their sparse slabs. It might not help tho.
             */
            small_mempool_group_sweep_sparse(alloc);
            ptr = mempool_alloc(pool);
        }

        if (ptr != NULL && small_mempool->used_pool != small_mempool) {
            /*
             * Waste for this allocation is the difference between
             * the size of objects optimal (i.e. best-fit) mempool and
             * used mempool.
             */
            small_mempool->waste +=
                (small_mempool->used_pool->pool.objsize -
                 small_mempool->pool.objsize);
            /*
             * In case when waste for this mempool becomes greater than
             * or equal to waste_max, we are updating the information
             * for the mempool group that this mempool belongs to,
             * that it can now be used for memory allocation.
             */
            if (small_mempool->waste >= small_mempool->group->waste_max)
                small_mempool_activate(small_mempool);
        }

        return ptr;
    }

.. _small_class:

Small class
~~~~~~~~~~~

**small_alloc** uses a collection of mempools of different sizes.
If small_alloc stores all mempools in an array then it have to determine
an offset in that array where the most suitable mempool is.
Let's name the offset as 'size class' and the size that the corresponding
mempool allocates as 'class size'.

Historically the class sizes grow incrementally up to some point and then
(at some size class) grow exponentially with user-provided factor.
Apart from incremental part the exponential part is not very obvious.
Binary search and floating-point logarithm could be used for size class
determination but both approaches seem to be too slow.

This module is designed for faster size class determination.
The idea is to use integral binary logarithm (bit search) and improve it
in some way in order to increase precision - allow other logarithm bases
along with 2.

Binary integral logarithm is just a position of the most significant bit of
a value. Let's look closer to binary representation of an allocation size
and size class that is calculated as binary logarithm:

.. code-block:: text

      size      |  size class
   00001????..  |      x
   0001?????..  |    x + 1
   001??????..  |    x + 2

Let's take into account n lower bits just after the most significant
in the value and divide size class into 2^n subclasses. For example if n = 2:

.. code-block:: text

      size      |  size class
   0000100??..  |      x
   0000101??..  |    x + 1
   0000110??..  |    x + 2
   0000111??..  |    x + 3
   000100???..  |    x + 4  <- here the size doubles, in 4 = 2^n steps.
   000101???..  |    x + 5

That gives us some kind of approximation of a logarithm with a base equal
to pow(2, 1 / pow(2, n)). That means that for given factor 'f' of exponent
we can choose such a number of bits 'n' that gives us an approximation of
an exponent that is close to 'f'.

Of course if the most significant bit of a value is less than 'n' we can't
use the formula above. But it's not a problem since we can (and even would
like to!) use an incremental size class evaluation of those sizes.

.. code-block:: text

    size      |  size class
   0000001    |      1  <- incremental growth.
   0000010    |      2
   0000011    |      3
   0000100    |      4  <- here the exponential approximation starts.
   0000101    |      5
   0000110    |      6
   0000111    |      7
   000100?    |      8
   000101?    |      9

There's some implementation details. Size class is zero based, and the size
must be rounded up to the closest class size. Even more, we want to round
up size to some granularity, we doesn't want to have incremental pools of
sizes 1, 2, 3.., we want them to be 8, 16, 24.... All that is achieved by
subtracting size by one and omitting several lower bits of the size.

..  _small-class-definitions:

Small class definition
~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: c

    /* lib/small/include/small/small_class.h */
    struct small_class {
        /** Every class size must be a multiple of this. */
        unsigned granularity;
        /** log2(granularity), ignore those number of the lowest bit of size. */
        unsigned ignore_bits_count;
        /**
         * A number of bits (after the most significant bit) that are used in
         * size class evaluation ('n' in the Explanation above).
         */
        unsigned effective_bits;
        /** 1u << effective_bits. */
        unsigned effective_size;
        /** effective_size - 1u. */
        unsigned effective_mask;
        /**
         * By default the lowest possible allocation size (aka class size of
         * class 0) is granularity. If a user wants different min_alloc, we
         * simply shift sizes; min_alloc = granularity + size_shift.
         */
        unsigned size_shift;
        /** Actually we need 'size_shift + 1', so store it. */
        unsigned size_shift_plus_1;
        /**
         * Exponential factor, approximation of which we managed to provide.
         * It is calculated from requested_factor, it's guaranteed that
         * it must be in range [requested_factor/k, requested_factor*k],
         * where k = pow(requested_factor, 0.5).
         */
        float actual_factor;
    };

..  _small-class-methods:

Small class methods
~~~~~~~~~~~~~~~~~~~

As we remember, we used *small_mempool_search()* function in order to find
needed mempool. It uses *small_class_calc_offset_by_size*, which implements
the algorithm described below, for that:

.. code-block:: c

    /* lib/small/small/small.c */
    static inline struct small_mempool *
    small_mempool_search(struct small_alloc *alloc, size_t size)
    {
        if (size > alloc->objsize_max)
            return NULL;
        unsigned cls =
            small_class_calc_offset_by_size(&alloc->small_class, size);
        struct small_mempool *pool = &alloc->small_mempool_cache[cls];
        return pool;
    }

    /* lib/small/small/small_class.c */
    static inline unsigned
    small_class_calc_offset_by_size(struct small_class *sc, unsigned size)
    {
        /*
         * Usually we have to decrement size in order to:
         * 1)make zero base class.
         * 2)round up to class size.
         * Also here is a good place to shift size if a user wants the lowest
         * class size to be different from granularity.
         */
        unsigned checked_size = size - sc->size_shift_plus_1;
        /* Check overflow. */
        size = checked_size > size ? 0 : checked_size;
        /* Omit never significant bits. */
        size >>= sc->ignore_bits_count;
    #ifndef SMALL_CLASS_BRANCHLESS
        if (size < sc->effective_size)
            return size; /* Linear approximation, faster part. */
        /* Get log2 base part of result. Effective bits are omitted. */
        unsigned log2 = small_class_fls(size >> sc->effective_bits);
    #else
        /* Evaluation without branching */
        /*
         * Get log2 base part of result. Effective bits are omitted.
         * Also note that 1u is ORed to make log2 == 0 for smaller sizes.
         */
        unsigned log2 = small_class_fls((size >> sc->effective_bits) | 1u);
    #endif
        /* Effective bits (and leading 1?) in size, represent small steps. */
        unsigned linear_part = size >> log2;
        /* Log2 part, multiplied correspondingly, represent big steps. */
        unsigned log2_part = log2 << sc->effective_bits;
        /* Combine the result. */
        return linear_part + log2_part;
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
subsystems.

Alongside with many other **allocations**, the most interesting one is
``memtx_index_extent_alloc`` function, used as the allocation function for
**memtx index** needed by **matras**, which works in pair with
``memtx_index_extent_reserve``. The ``memtx_index_extent_reserve`` is being
called when we are going to **build** or **rebuild index** to make sure that
we have enough **reserved extents**. Otherwise, ``memtx_index_extent_reserve``
tries to allocate **extents** until we get the given number and aborts if it
can't be done. This allows us to stick to consistency and abort the operation
before it is too late.

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

Matras is a **Memory Address TRAnSlation allocator**, providing aligned
identifiable blocks of specified size (N) and a 32-bit integer identifiers
for each returned block. Block identifiers grow incrementally starting from 0.
It is designed to maintain index with versioning and consistent read views.

The block size (N) must be a power of 2 (checked by assert in
the debug build). matras can restore a pointer to the block
give block ID, so one can store such 32-bit ids instead of
storing pointers to blocks.

Since block IDs grow incrementally from 0 and matras
instance stores the number of provided blocks, there is a
simple way to iterate over all provided blocks.

Implementation
~~~~~~~~~~~~~~

To support block allocation, matras allocates extents of memory
by means of the supplied allocator, each extent having the same
size (M), M is a power of 2 and a multiple of N.
There is no way to free a single block, except the last one,
allocated, which happens to be the one with the largest ID.
Destroying a matras instance frees all allocated extents.

Address translation
~~~~~~~~~~~~~~~~~~~

To implement 32-bit address space for block identifiers,
matras maintains a simple tree of address translation tables.

    * First N1 bits of the identifier denote a level 0 extend
      id, which stores the address of level 1 extent.

    * Second N2 bits of block identifier stores the address
      of a level 2 extent, which stores actual blocks.

    * The remaining N3 bits denote the block number
      within the extent.

Actual values of N1 and N2 are a function of block size B,
extent size M and sizeof(void \*).

To sum up, with a given N and M matras instance:

    1) can provide not more than
       pow(M / sizeof(void*), 2)(M / N) blocks

    2) costs 2 random memory accesses to provide a new block
       or restore a block pointer from block id

    3) has an approximate memory overhead of size (LM)

Of course, the integer type used for block id (matras_id_t,
usually is a typedef to uint32) also limits the maximum number
of objects that can be allocated by a single instance of matras.

Versioning
~~~~~~~~~~

Starting from Tarantool 1.6, matras implements a way to create
a consistent read view of allocated data with
matras_create_read_view(). Once a read view is
created, the same block identifier can return two different
physical addresses in two views: the created view
and the current or latest view. Multiple read views can be
created.  To work correctly with possibly existing read views,
the application must inform matras that data in a block is about to
change, using matras_touch() call. Only a block which belong to
the current, i.e. latest, view, can be changed: created
views are immutable.

The implementation of read views is based on copy-on-write
technique, which is cheap enough as long as not too many
objects have to be touched while a view exists.
Another important property of the copy-on-write mechanism is
that whenever a write occurs, the writer pays the penalty
and copies the block to a new location, and gets a new physical
address for the same block id. The reader keeps using the
old address. This makes it possible to access the
created read view in a concurrent thread, as long as this
thread is created after the read view itself is created.


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
