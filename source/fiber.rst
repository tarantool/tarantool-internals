.. vim: ts=4 sw=4 et

Fibers
======

Introduction
------------

Tarantool uses cooperative multitasking via that named fibers.
They are similar to well-known threads except they are not running
simultaneously but must be scheduled explicitly.

Fibers are coupled into cords (in turn the cords are real threads,
thus fibers inside a cord are executing in a sequent way while several
cords may run simultaneously).

When we create a fiber we provide a function to be invoked upon fiber's
start, let's call it a fiber function to distinguish from other
service routines.

Event library
-------------

The heart of Tarantool fibers schedule is ``libev`` library.
As its name implies the library provides a loop which get interrupted
when an event arrive. We won't jump into internals of ``libev``
but provide only a few code snippets to draw a basic workflow.

.. code-block:: c

    /* third_party/libev/ev.c */
    ev_run (int flags) {
        do {
            //...
            backend_poll(waittime);
            //...
            EV_INVOKE_PENDING;
        }
    }

The ``backend_poll`` invokes low-level service call (such as ``epoll`` or
``select`` depending on the operating system, please see their man pages)
to fetch events. Events are explicitly passed to a queue via API ``libev``
provides to programmers. The service call supports ``waittime`` timeout,
so if no events are available a new wait iteration is started or polling,
to be precise. The typical minimal ``waittime`` is 1 millisecond.

The ``EV_INVOKE_PENDING`` fetches events to process and runs associated
callbacks for this iteration. Once callbacks are finished a new iteration
begins.

Pushing a new event into the queue is provided by ``ev_feed_event`` call
and Tarantool uses it under the hood.

Thread model
------------

Tarantool instance has the following cords (threads):

    - Network thread (see ``iproto``) is used for sending requests to another
      instance and receiving responses. E.g. on the server side it receives
      the query, parses the statement, checks if it is correct, and then
      transforms it into a special structure.

    - Replication counterparts (see :ref:`relay` and applier
      in :ref:`replication`). Applier's fibers are used to fetch updates from
      the master. Relay's fibers, on the other hand, send these changes to
      replicas. Both of the cords communicates (see :ref:`cbus`) with tx
      cords, where replication takes place (Actually, relay also
      communicates with the WAL thread via the ``wal_watcher``,
      in which the relay thread is notified on every new WAL write,
      after this notification it advances the xlog cursor in the file and
      sends new rows (see :ref:`relay` and :ref:`wal`)).

    - Tx thread. The iproto and applier ships message to the instance’s
      transaction processor thread (tx thread), where all database changes
      take place. Lua programs are also executed directly in the transaction
      processor thread.

    - WAL thread (see :ref:`wal`).The execution of operation will result in a
      message to the write-ahead logging thread to commit the transaction and
      the fiber executing the transaction will be suspended. When the
      transaction will result in a COMMIT or ROLLBACK, WAL thread will reply
      with a message to the TX, fiber will be resumed to have an ability to
      process the result of transaction and the result of fiber execution
      will be passed to the network thread, and the network thread returns
      the result to the client.

Here is the general overview of the Tarantool's threads and connections
between them:

.. code-block:: text

                IPROTO thread                       Applier thread
          (Encode/decode the request)     (Receive the request from the other
                      ^                       node's relay and decode it)
                      |                                   ^
                      V                                   |
                  TX thread <-----------------------------+
      (Use space index in order to find and
    update the tuple, prepare for the commit) <-----------+
                      ^                                   |
                      |                                   |
                      V                                   V
                  Relay thread <-------------------> WAL thread
        (Advance xlog cursor and send new    (Write the request to the xlog)
                rows to the replicas)

Let's see how the messages travel through the various threads. The first one
is a DML request, which is initiated by a user via a Tarantool connector.
Such request goes through the following way:

.. code-block:: text

          IPROTO thread
       (Decode the request)
               |
               V
           TX thread
     (Process it and prepare
    for the transaction commit)
               |
               V      (if any relay exists)
           WAL thread ---------------------+
      (Write to the xlog)                  |
               |                           |
               V                           V
           TX thread                  Relay thread
     (Commit the transaction)     (Send new rows to the replica)
               |                           |
               V                           V
          IPROTO thread                TX thread
    (Send result to the user)    (Update the status (e.g.
                                  vclock) of the replica)

As soon as the request is written to the disk in the WAL thread we invoke
a wal_watcher's callbacks, which sends new rows to the replicas. On the
replica side it looks like that:

.. code-block:: text

           Applier thread
    (Receive the request from the other
        node's relay and decode it)
                 |
                 V
             TX thread
       (Process it and prepare
      for the transaction commit)
                 |
                 V
    (The same as on the above diagram)

Fibers engine overview
----------------------

The main cord defined as:

.. code-block:: c

    /* lib/core/fiber.c */
    static struct cord main_cord;
    __thread struct cord *cord_ptr = NULL;

It's also called ``tx`` (transaction processor) thread and it's the
only thread, which works with the database changes.

Note the ``cord()``, ``fiber()`` and ``loop()`` helper macros:

.. code-block:: c

    /* lib/core/fiber.h */
    #define cord()    cord_ptr
    #define fiber()   cord()->fiber
    #define loop()    (cord()->loop)

They are used frequently in the following code blocks to access the
currently executing cord, fiber and event loop.

The cord structure is the following (note that we are posting stripped
versions of structures for the sake of simplicity)

.. code-block:: c

    /* lib/core/fiber.h */
    struct cord {
        /* Currently running fiber */
        struct fiber        *fiber;

        /* Libev loop */
        struct ev_loop      *loop;

        /* Fiber's ID map (id -> fiber) */
        struct mh_i32ptr_t  *fiber_registry;

        /* All fibers */
        struct rlist        alive;

        /* Fibers ready for execution */
        struct rlist        ready;

        /* A cache of dead fibers for reuse */
        struct rlist        dead;

        /* The "main" fiber of this cord, the scheduler. */
        struct fiber        sched;

        /* Cord's name */
        char                name[FIBER_NAME_MAX];
    }

Pay attention to the following members as they are widely used below:
 - ``fiber`` is a currently executing fiber
 - ``sched`` is a service fiber which schedules all other fibers in the cord

As we've already said, each cord consists of fibers to implement cooperative
multitasking model. The fiber structure is the following:

.. code-block:: c

    /* lib/core/fiber.h */
    struct fiber {
        /* The fiber to be scheduled when this one yields */
        struct fiber    *caller;

        /* Carries FIBER_IS_x flags */
        uint32_t            flags;

        /* Fiber ID */
        uint32_t        fid;

        /* Link in cord->alive or cord->dead list. */
        struct rlist    link;

        /* Link in cord->ready list. */
        struct rlist    state;

        /* The list of fibers awaiting for this fiber's death */
        struct rlist    wake;

        /* Fiber function, its arguments and return code */
        fiber_func      f;
        va_list         f_data;
        int             f_ret;
    }

When Tarantool starts it creates the main cord:

.. code-block:: c

    /* main.cc */
    main(int argc, char **argv)
        /* lib/core/fiber.c */
        fiber_init(fiber_cxx_invoke);
            /* fiber_init() code */
            ...
            fiber_invoke = fiber_cxx_invoke;
            main_thread_id = pthread_self();
            main_cord.loop = ev_default_loop();
            cord_create(&main_cord, "main");
            fiber_signal_init();

Don't pay attention to ``fiber_cxx_invoke`` for now, it is just
a wrapper to run a fiber function. The cord creation, which was
invoked for the ``main`` cord, is the following:

.. code-block:: c

    /* lib/core/fiber.c */
    cord_create(&main_cord, "main");
        cord() = cord;
        cord->id = pthread_self();

        ...
        rlist_create(&cord->alive);
        rlist_create(&cord->ready);
        rlist_create(&cord->dead);
        cord->fiber_registry = mh_i32ptr_new();

        /* Scheduler fiber initialization */
        rlist_create(&cord->sched.state);
        rlist_create(&cord->sched.link);
        ...
        cord->sched.fid = 1;
        fiber_set_name(&cord->sched, "sched");
        cord->fiber = &cord->sched;

        ev_async_init(&cord->wakeup_event, fiber_schedule_wakeup);
        ev_idle_init(&cord->idle_event, fiber_schedule_idle);

When the cord is created the **scheduler fiber** ``cord->sched``
becomes its primary one. Just for now think of it as a main fiber
which will switch all other fibers in this cord (we'll dive into
the scheduling process a little bit later).

Note that here we setup ``cord()`` macro to point to ``main_cord``;
thus ``fiber()`` will point to the main cord scheduler fiber and
``loop()`` will be ``ev_default_loop``.

An abstract description is not very useful so let's look at how Tarantool
boots in interactive console mode (the mode is not really important
here but rather a call graph).

.. code-block:: c

    /* main.cc */
    main(int argc, char **argv)
        ...
        fiber_init(fiber_cxx_invoke);
        ...
        /* lua/init.c */
        tarantool_lua_run_script(...)
            /* tarantool_lua_run_script() code */
            script_fiber = fiber_new(title, run_script_f);
                /* fiber_new() code */
                return fiber_new_ex(title, fiber_attr_default, f)
                    /* fiber_new_ex() code */
                    cord = cord();
                    ...
                    if (... && !rlist_empty(&cord->dead)) {
                        fiber = rlist_first_entry(&cord->dead,
                            struct fiber, link);
                        rlist_move_entry(&cord->alive, fiber, link);
                    } else {
                        fiber = (struct fiber *)
                            mempool_alloc(&cord->fiber_mempool);
                        ...
                        coro_create(..., fiber_loop,...)
                        ...
                        rlist_add_entry(&cord->alive, fiber, link);
                    }
                    ...
                    register_fid(fiber);

Here we create a new fiber to run ``run_script_f`` fiber function.
``fiber_new`` allocates a new fiber instance (actually, there is a fiber
cache so that if a previous fiber already finished its work and exited we
can reuse it without calling ``mempool_alloc``, see scheduling part below),
then we chain it into the main cord's ``alive`` list and register in the
fiber IDs pool.

One of the clues here is ``coro_create`` call, where "coro"
stands for "coroutine". Coroutines are implemented via ``coro``
library. On Linux it simply handles hardware context to reload
registers and jump into the desired function. More precisely the heart of
"coro" library is ``coro_transfer(&from, &to)`` routine which remembers
current point of execution (``from``) and transfers flow to the new
instruction pointer provided (``to`` which is created during
``coro_create``).

Note that the fiber function is wrapped in the ``fiber_loop``.
This is done in order to wake up all fibers, which are waiting for the
current one to complete, in order to transfer the context to the caller
of the current fiber and in order to recycle the fiber if it wasn't already:

.. code-block:: c

    /* lib/core/fiber.c */
    fiber_loop(MAYBE_UNUSED void *data)
        for (;;) {
            ...
            fiber->f_ret = fiber_invoke(fiber->f, fiber->f_data);
            ...
            fiber->flags |= FIBER_IS_DEAD;
            while (!rlist_empty(&fiber->wake)) {
                /* Some fibers waits for us to complete via fiber_join() */
                f = rlist_shift_entry(&fiber->wake, struct fiber,
                                      state);
                fiber_wakeup(f);
                    /* fiber_wakeup() code */
                    ...
                    rlist_move_tail_entry(&cord->ready, f, state);
            }

            ...
            if (!(fiber->flags & FIBER_IS_JOINABLE))
                fiber_recycle(fiber);

            fiber->f = NULL;
            fiber_yield();
        }

Some fibers may wait for others to be finished, for this sake we
move them to ``ready`` list of the cord first, then we try to
put the fiber into a cache pool (``cord()->dead``) to recycle it
(thus don't allocate memory again) via ``fiber_recycle`` and
finally we move execution flow back to the scheduler fiber via
``fiber_yield``.

Note that in case there's the waiting fiber in the ``fiber->wake``
recycling won't be done in the ``fiber_loop`` itself but in the
``fiber_join_timeout``.

Fibers do not start execution automatically, we have to call
``fiber_start``. Thus back to Tarantool startup:

.. code-block:: c

    /* lua/init.c */
    tarantool_lua_run_script(...)
        script_fiber = fiber_new(title, run_script_f);
        /* lib/core/fiber.c */
        fiber_start(script_fiber, ...)
            fiber_call(...)
                fiber_call_impl(...)
                    coro_transfer(...)
        ev_run(loop(), 0);

Here once the fiber is created we kick it to execute. This is done
inside ``fiber_call_impl`` which uses ``coro_transfer``
routine to jump into ``fiber_loop`` and invoke ``run_script_f``
inside.

The ``run_script_f`` shows a good example of how to give execution
back to scheduler fiber and continue:

.. code-block:: c

    /* lua/init.c */
    run_script_f
        ...
        fiber_sleep(0.0);
        ...

When ``fiber_sleep`` is called, the ``coro`` switch execution to the
scheduler fiber

.. code-block:: c

    /* lib/core/fiber.c */
    fiber_sleep(double delay)
        ...
        fiber_yield_timeout(delay);
            ...
            fiber_yield();
                cord = cord();
                caller->caller = &cord->sched;
                coro_transfer(&caller->ctx, &callee->ctx);

Once ``coro`` jumped into the scheduler fiber another fiber is
chosen to execute. At some moment scheduler returns execution
to the point after ``fiber_sleep(0.0)`` and we step up back
to ``tarantool_lua_run_script`` and run main event loop
``ev_run(loop(), 0)``. Now all future execution will be driven
by ``libev`` and by events we supply into the queue.

The full description of the fiber API is provided in Tarantool
manual but we mention a few just to complete this introduction:

 - ``cord_create`` to create a new cord;
 - ``fiber_new`` to create a new fiber but not run it;
 - ``fiber_start`` to execute a fiber immediately;
 - ``fiber_cancel`` to cancel the execution of a fiber;
 - ``fiber_join`` to wait for a cancelled fiber;
 - ``fiber_yield`` to switch execution to another fiber,
   the execution will back to the point after this call later.
   By later we mean that some other fiber will call ``fiber_wakeup``
   on this fiber, until then it won't be scheduled. This is the key
   function of fibers switch;
 - ``fiber_sleep`` to sleep some time giving execution
   to another fiber;
 - ``fiber_yield_timeout`` to give execution to another
   fibers with some timeout value;
 - ``fiber_reschedule`` give execution to another fiber.
   In contrast with plain ``fiber_yield`` we are moving self
   to the end of cord's ``ready`` list. We will grab execution
   back when all fibers already waiting for execution are
   processed.

Fiber's scheduling
------------------

Due to cooperative multitasking, we have to provide scheduling points
explicitly. Still from API point of view, it is not very clear how exactly
fibers are chosen for execution and how they are managed on a low level. Here
we explain some details.

Let's put transition schematics immediately so the next explanation will be pictured.

.. code-block:: text

    Prepend newly created fibers to the list

    cord_X->alive
            `-> fiber_1->link
            `-> fiber_2->link
            `-> fiber_x->link

    Once fiber is exited cache it moving from @alive to @dead list

    cord_X->alive
            `-x fiber_1->link ---
            `-x fiber_2->link -- `
            `-x fiber_x->link - ` `
                               `-`-`-> cord_X->dead

    Instead of creating new fibers we can reuse exited ones

    cord_X->dead
            `-x fiber_1->link ---
            `-x fiber_2->link -- `
            `-x fiber_x->link - ` `
                               `-`-`-> cord_X->alive

Each cord has a statically allocated scheduler fiber.
Note that ``cord->sched`` is not a pointer but embedded complete structure.
So when cord is created the ``sched`` is initialized manually.

.. code-block:: c

    /* lib/core/fiber.c */
    void
    cord_create(struct cord *cord, const char *name)
    {
        ...
        /* To control children fibers state */
        rlist_create(&cord->alive);
        rlist_create(&cord->ready);
        rlist_create(&cord->dead);

        cord->sched.fid = FIBER_ID_SCHED;
        fiber_reset(&cord->sched);
        fiber_set_name(&cord->sched, "sched");
        cord->fiber = &cord->sched;

        ...
        /* Event loop will trigger this helpers */
        ev_async_init(&cord->wakeup_event, fiber_schedule_wakeup);
        ev_idle_init(&cord->idle_event, fiber_schedule_idle);

        ...
        /* No need for separate stack */
        cord->sched.stack = NULL;
        cord->sched.stack_size = 0;
    }

The ``cord->sched`` does not even have a separate stack because the cord and
its scheduler are executed inside the main thread itself (actually cord may
be running inside separate thread as well but still doesn't require its own
stack to have).

Binding to ``libev`` is done via ``ev_async_init`` and ``ev_idle_init``
calls (see ``man libev`` or `the official website
<http://software.schmorp.de/pkg/libev.html>`_).

Now let's create a new fiber and run it.

.. code-block:: c

    /* lib/core/fiber.c */
    struct fiber *
    fiber_new_ex(const char *name, const struct fiber_attr *fiber_attr, fiber_func f)
    {
        struct cord *cord = cord();

        ...
        /* Either take the fiber from cache, or allocate a new one */
        if (... && !rlist_empty(&cord->dead)) {
            /* When fiber is reused we move it from the dead list to alive */
            fiber = rlist_first_entry(&cord->dead, struct fiber, link);
            rlist_move_entry(&cord->alive, fiber, link);
        } else {
            fiber = mempool_alloc(&cord->fiber_mempool);
            ...
            rlist_create(&fiber->state);
            rlist_create(&fiber->wake);

            ...
            /* New fiber created, prepend to alive */
            rlist_add_entry(&cord->alive, fiber, link);
        }

        /* Main function to run when fiber is executing */
        fiber->f = f;

        /* New fibers are prepends the @cord->alive list */
    }

Upon a new fiber creation, we put it to the head of ``cord->alive`` list via
``fiber->link`` list. It is not running yet we have to give it an execution
slot explicitly via ``fiber_start`` call (which is just a wrapper over
``fiber_call``).

.. code-block:: c

    /* lib/core/fiber.c */
    void
    fiber_start(struct fiber *callee, ...)
    {
        va_start(callee->f_data, callee);
        fiber_call(callee);
        va_end(callee->f_data);
    }

    void
    fiber_call(struct fiber *callee)
    {
        ...
        callee->caller = caller;
        callee->flags |= FIBER_IS_READY;
        caller->flags |= FIBER_IS_READY;
        fiber_call_impl(callee);
    }

The fiber to execute remembers its caller via ``fiber->caller``. And the
``fiber_call_impl`` does a real transfer of an execution context.

.. code-block:: c

    /* lib/core/fiber.c */
    static void
    fiber_call_impl(struct fiber *callee)
    {
        struct fiber *caller = fiber();
        struct cord *cord = cord();

        // Remember the fiber we're executing now.
        cord->fiber = callee;

        callee->flags &= ~FIBER_IS_READY;
        coro_transfer(&caller->ctx, &callee->ctx);
    }

We set the currently running fiber to ``cord->fiber`` and jump into fiber's
execution. Note at this moment the fiber is sitting in ``cord->alive`` list.
Same time we drop ``FIBER_IS_READY`` flag from us since we're already
executing and if we're trying to wake up self we will exit early.

Once we start executing we could either

 - finish execution explicitly, exiting from fiber's function ``f`` we passed
   as an argument upon fiber creation;
 - give execution slot to some other fiber via ``fiber_yield`` call.

Fiber exit
~~~~~~~~~~

When fiber is exiting the execution flow returns to ``fiber_loop``.

.. code-block:: c

    /* lib/core/fiber.c */
    static void
    fiber_loop(MAYBE_UNUSED void *data)
    {
        for (;;) {
            struct fiber *fiber = fiber();
            fiber->f_ret = fiber_invoke(fiber->f, fiber->f_data);

            /**
             * Upon exit we return to this point since fiber_invoke
             * finished its execution
             */

            ...
            fiber->flags |= FIBER_IS_DEAD;

            /* Wakeup all waiters */
            while (!rlist_empty(&fiber->wake)) {
                struct fiber *f;

                f = rlist_shift_entry(&fiber->wake, struct fiber, state);
                fiber_wakeup(f);
            }

            /* Remove pending wakeups */
            rlist_del(&fiber->state);

            /* Put into dead fibers cache for reuse */
            if (!(fiber->flags & FIBER_IS_JOINABLE))
                fiber_recycle(fiber);

            /* Give execution back to the main scheduler */
            fiber_yield();
        }
    }

In a simple scenario we just move this fiber to the ``cord->dead`` list via
``fiber_recycle`` and reuse it later when we need to create a new fiber.

An interesting scenario is where there are some waiters. *Waiters* mean that
there are some fibers which wait for our exit. In terms of API it means that
another fiber has called ``fiber_join_timeout``.

.. code-block:: c

    /* lib/core/fiber.c */
    int
    fiber_join(struct fiber *fiber)
    {
        return fiber_join_timeout(fiber, TIMEOUT_INFINITY);
    }

    bool
    fiber_wait_on_deadline(struct fiber *fiber, double deadline)
    {
        rlist_add_tail_entry(&fiber->wake, fiber(), state);
        return fiber_yield_deadline(deadline);
    }

    int
    fiber_join_timeout(struct fiber *fiber, double timeout)
    {
        if ((fiber->flags & FIBER_IS_JOINABLE) == 0)
            panic("the fiber is not joinable");

        if (!fiber_is_dead(fiber)) {
            double deadline = fiber_clock() + timeout;
            while (!fiber_wait_on_deadline(fiber, deadline) &&
                   !fiber_is_dead(fiber)) {
            }
            if (!fiber_is_dead(fiber)) {
                diag_set(TimedOut);
                return -1;
            }
        }

        /* Do not allow to join the fiber several times */
        fiber->flags &= ~FIBER_IS_JOINABLE;
        /* Move exception to the caller */
        int ret = fiber->f_ret;
        ...
        /* The fiber is already dead. */
        fiber_recycle(fiber);
        return ret;
    }


The key moment here is that the target fiber which we are waiting to exit
puts us to own ``fiber->wake`` list. Thus we become a *waiting* fiber
and call ``fiber_yield`` (inside the ``fiber_yield_deadline``) all the time
(we don't consider a case where we wait with timeout because the only
difference is that we can exit earlier due to timeout expiration) skipping
our execution slot giving control back to the scheduler. The target fiber
will wake us upon its completion. It is done via tail of ``fiber_loop``
call. Let's repeat this moment:

.. code-block:: c

    /* lib/core/fiber.c */
    static void
    fiber_loop(MAYBE_UNUSED void *data)
    {
        for (;;) {
            ...
            // Wakeup all waiters
            while (!rlist_empty(&fiber->wake)) {
                struct fiber *f;
                f = rlist_shift_entry(&fiber->wake, struct fiber, state);
                fiber_wakeup(f);
            }

            ...
            // Give control back to scheduler
            fiber_yield();
        }
    }

Thus here is an interesting transition. Let's assume we've a few fibers:
``fiber-1`` and ``fiber-2``. Both are not running just hanging in ``cord->alive`` list.

.. code-block:: text

    cord->alive
            `-> fiber-1->link
            `-> fiber-2->link

Then we need the ``fiber-2`` to wait until ``fiber-1`` is finished. So we
mark ``fiber-1`` via ``fiber_set_joinable(fiber-1, true)`` and then start
waiting for it to complete via ``fiber_join(fiber-1)`` call. The
``fiber_join`` simply gives an execution slot to the scheduler which runs
``fiber-1``. Once ``fiber-1`` finishes it notifies scheduler to wake up
waiting ``fiber-2`` and enters into ``fiber_yield``. Then the scheduler
finally gives execution back to ``fiber-2`` which in turn rips ``fiber-1``
via ``fiber_recycle`` and continues its own execution.

Here is how this transition goes.

.. code-block:: text

    cord->alive
          `
           |        fiber_yield() --> scheduler --+
           |       /                              |
           |      fiber_wake()                    |
           |     /                                |
           `-> fiber-1->link                      |
           |      `                               |
           |       `--> wake <-+                  |
           |                   |                  |
           |                   |                  |
           |         -- state -+                  |
           |        /                             |
           `-> fiber-2->link                      |
                `fiber_yield()                    |
                  ` fiber_recycle(fiber-1) <------+

                           |
                           | remove fiber-1->link from
                           | cord->alive list
                           V

    cord->alive
        |  `-> fiber-2->link
        `->dead
           `-> fiber-1->link

Fiber yield
~~~~~~~~~~~

Now let's look into ``fiber_yield`` implementation.

.. code-block:: c

    /* lib/core/fiber.c */
    void
    fiber_yield(void)
    {
        struct cord *cord = cord();
        struct fiber *caller = cord->fiber;
        struct fiber *callee = caller->caller;
        caller->caller = &cord->sched;

        ...
        callee->flags &= ~FIBER_IS_READY;
        cord->fiber = callee;
        callee->flags = (callee->flags & ~FIBER_IS_READY) | FIBER_IS_RUNNING;

        coro_transfer(&caller->ctx, &callee->ctx);
    }

The ``caller`` is our fiber which calls ``fiber_yield`` and the fiber to
switch execution to is our ``fiber->caller`` member.

Initially this ``fiber->caller`` is set in ``fiber_call`` routine. In
other words when fiber is executed for first time because there must
be some parent fiber which created and run the new fibers.

.. code-block:: text

    cord->sched
            `<- fiber_1->caller
                 `<- fiber_2->caller
                      `-> fiber_yield()

                      switch to fiber_1

                             |
                             V

    cord->sched
            `<- fiber_2->caller
            `<- fiber_1->caller

So using ``caller`` value we switch execution to ``fiber_1`` because
it is a parent of ``fiber_2`` but this is a one-shot action. Same time
we reset ``fiber_1`` caller to the main scheduler ``cord->sched`` so the
next time these fibers will be running ``fiber_yield`` the execution will
be transferred to the scheduler.

Note that you cannot yield in the code, which is executed in the scheduler
fiber. The example of such code is all ``libev`` callbacks (e.g. endpoint
callbacks: ``tx_prio_cb``, ``fiber_pool_cb``) or the callbacks of the cbus's
messages hops (e.g. ``tx_complete_batch``). The scheduler fiber doesn't have
any ``caller`` field, which is accessed in the ``fiber_yield``.
So, yielding will result in SEGFAULT.

Fiber wakeup
~~~~~~~~~~~~

Once a fiber suspended its own execution slot to the caller (either a parent
fiber or the scheduler) it simply sits in memory doing nothing and someone
has to wake it up and run again. The parent (or any other fiber) has to call
``fiber_wakeup`` with this suspended fiber as an argument.

.. code-block:: c

    /* lib/core/fiber.c */
    void
    fiber_wakeup(struct fiber *f)
    {
        /* Exit early if calling fiber_wakeup on self or dead fibers */
        const int no_flags = FIBER_IS_READY | FIBER_IS_DEAD |
            FIBER_IS_RUNNING;
        if ((f->flags & no_flags) == 0)
            fiber_make_ready(f);
                /* fiber_make_ready() code */
                /* Notify scheduler to execute fiber_schedule_wakeup */
                struct cord *cord = cord();
                if (rlist_empty(&cord->ready)) {
                    ev_feed_event(cord->loop, &cord->wakeup_event,
                        EV_CUSTOM);
                }

                /* Move the target fiber to the @ready list */
                rlist_move_tail_entry(&cord->ready, f, state);
                f->flags |= FIBER_IS_READY;
    }

The ``fiber_wakeup`` notifies ``cord->wakeup_event`` listener that there
is an event to process. This will cause ``fiber_schedule_wakeup`` to run
once ``libev`` obtain control back. Then the target fiber is *appended*
to the ``cord->ready`` list. The order is important because we highly
depend on transactions order and WAL processing.

Note that calling ``fiber_wakeup`` does not cause ``fiber_schedule_wakeup``
to run immediately. The caller should give execution back to the scheduler
explicitly (via the same ``fiber_yield`` for example).

Finally the ``fiber_schedule_wakeup`` takes place:

.. code-block:: c

    /* lib/core/fiber.c */
    static void
    fiber_schedule_wakeup(ev_loop *loop, ev_async *watcher, int revents)
    {
        struct cord *cord = cord();
        fiber_schedule_list(&cord->ready);
    }

    fiber_schedule_list(struct rlist *list)
    {
        struct fiber *first;
        struct fiber *last;

        /* The fibers might be dead already */
        if (rlist_empty(list))
            return;

        /*
         * Traverse the queued fibers clearing the
         * @ready list and serialize the callers.
         */
        first = last = rlist_shift_entry(list, struct fiber, state);
        while (!rlist_empty(list)) {
            last->caller = rlist_shift_entry(list, struct fiber, state);
            last = last->caller;
        }

        /*
         * Set the caller to main scheduler of the last
         * entry from the @ready list, so its fiber_yeld
         * transfer execution back.
         */
        last->caller = &cord()->sched;

        /* And start execution of the first fiber. */
        fiber_call_impl(first);
    }

This is nontrivial code. There might be a series of ``fiber_wakeup`` calls
during some fiber execution. They are all queued in the ``cord->ready``
list. When we start execution of the scheduling routine the fibers might
be dead already so we exit early since there is nothing to execute.

Same time if the queue is not empty we try to serialize the ``fiber->caller``
chain. We traverse the ``cord->ready`` list left to right (remember the
fibers are appended to this list when ``fiber_wakeup`` is called) and
make each fiber be a parent of the next one. The last entry in the list
use main scheduler ``cord()->sched`` as a parent.

And finally we run first queued fiber. When it call ``fiber_yield`` then
the next previously queued fiber will be executed (as we remember
``fiber_yield`` switch execution to the ``fiber->caller``, which now point
to the next fiber in the ``cord->ready`` list, as we changed it). Let's try
to draw the transition.

Assume there is 3 fibers which creates each other in sequence.

.. code-block:: text

   cord->sched <---+
    `              |
     fiber-1       | <-+
      ` `- caller -+   |
      `                |
       `- fiber-2      | <-+
         `  `- caller -+   |
          `                |
           `- fiber-3 <~~~~|~~ running
                `- caller -+

Let's presume the ``fiber-3`` is running and calls ``fiber_yield``, then
we make its parent be ``cord->sched`` and transfer execution to ``fiber-2``.

.. code-block:: text

   cord->sched <---+-------+
    `              |       |
     fiber-1       | <-+   |
      ` `- caller -+   |   |
      `                |   |
       `- fiber-2 <~~~~|~~~|~~ running
         `  `- caller -+   |
          `                |
           `- fiber-3      |
                `- caller -+

In turn ``fiber-2`` does the same and calls ``fiber_yield`` too so the
execution comes back to ``fiber-1``.

.. code-block:: text

   cord->sched <---+---+---+
    `              |   |   |
     fiber-1 <~~~~~|~~~|~~~|~~ running
      ` `- caller -+   |   |
      `                |   |
       `- fiber-2      |   |
         `  `- caller -+   |
          `                |
           `- fiber-3      |
                `- caller -+

Let's assume that now ``fiber-1`` runs ``fiber_wakeup(fiber-2)``,
``fiber_wakeup(fiber-3)`` and ``fiber_yield``.

.. code-block:: text

   cord->sched <---+---+---+
    `              |   |   |
     fiber-1 <~~~~~|~~~|~~~|~~ running
      ` `- caller -+   |   |
      `                |   |
       `- fiber-2      |   |
         `  `- caller -+   |
          `                |
           `- fiber-3      |
                `- caller -+

                    |
                    V

        fiber-1: fiber_wakeup(fiber-2)
        fiber-1: fiber_wakeup(fiber-3)

                    |
                    V

        cord->alive { fiber-2, fiber-3 }

                    |
                    V

        fiber-1: fiber_yield() -> execute fiber_schedule_wakeup()

                    |
                    V

   cord->sched <---+--------+     +-- fiber_schedule_wakeup --+
    `              |        |     |                           |
     fiber-1 ~~~~~~|~~~~~~~~|~~~> fiber_yield() ->            |
      ` `- caller -+        |                                 |
      `                     |                                 V
       `- fiber-2 <~~~~~~~~~|~~~~~~~~~~ running ~~~~~~~~~~~~~~+
         `  `- caller --+   |
          `             |   |
           `- fiber-3 <-+   |
                `- caller --+

When ``fiber-1`` calls ``fiber_yield`` the main scheduler obtains the
execution slot and reorders ``caller`` chain so that ``fiber-2`` starts
running but its ``caller`` now points to ``fiber-3``, and when ``fiber-2``
calls ``fiber_yield()`` the next target to execute is ``fiber-3``.

When ``fiber-3`` make its own ``fiber_yield()`` the transition goes back to
the main scheduler and ``caller`` for all three fibers point to main
scheduler again.

.. code-block:: text

   cord->sched <---+---+---+   <~~~ running
    `              |   |   |
     fiber-1       |   |   |
      ` `- caller -+   |   |
      `                |   |
       `- fiber-2      |   |
         `  `- caller -+   |
          `                |
           `- fiber-3      |
                `- caller -+

Thus the only purpose of ``fiber_wakeup`` is to order execution of
other fibers.
