.. vim: ts=4 sw=4 et
.. _wal:

Write-ahead logging
===================

Write-ahead logging WAL is one of the most important parts of
databases which implements atomicity and durability. The base
idea of logging is to write the data to the storage before make
this data accessible by others.

We will reference 2.x series of Tarantool source code.

Journal subsystem
-----------------

The journal subsystem provides the following API calls:

 - ``journal_create`` to create a new journal;
 - ``journal_set`` to destroy old journal and set a new one;
 - ``journal_entry_new`` to create a new journal entry;
 - ``journal_write`` to write a journal entry.

There might be only one active journal at a time which is
referred via ``current_journal`` variable (thus we can
create as many journals as we need with ``journal_create``
but only one must be activated via ``journal_set``).

The ``journal_entry_new`` requires a callback to be associated
with the journal entry to be called when entry processing is complete
(with success or failure). Since we use journal to process database
transactions we pass ``txn_on_journal_write`` as a callback and a
pointer to the transaction itself as a data.

To explain in details how transactions are processed on journal
level we need to look at transaction structure (short version
to be precise, only with the members we're interesed in).

.. code-block:: c

    /* box/txn.h */
    struct txn {
        /* Transaction cache */
        struct stailq_entry in_txn_cache;
        /* Memory to keep transaction data */
        struct region region;
        /* Transaction ID */
        int64_t id;
        /* LSN assigned by WAL or -1 on error */
        int64_t signature;
        /* A fiber initiated the transaction */
        struct fiber *fiber;
    };

A transaction is allocated via ``txn_new`` call. The memory allocation
is a bit tricky here. We request memory region from the main ``cord``
where we allocate the ``txn`` itself and may increase memory usage if
``txn`` need additional data to carry. On ``txn_free`` the additional
memory get freed and we put ``txn`` to cache for fast reuse.

TODO: describe ``tx_on_journal_write``
TODO: mention that the use of journal and transactions are described below

WAL thread
----------

Because writing data to the real storage such as hardware drive
is a way too slower than plain memory access the storage operations
are implemented in a separate thread.

.. code-block:: c

    /* box/wal.c */
    int
    wal_init(enum wal_mode wal_mode, const char *wal_dirname,
             int64_t wal_max_size, const struct tt_uuid *instance_uuid,
             wal_on_garbage_collection_f on_garbage_collection,
             wal_on_checkpoint_threshold_f on_checkpoint_threshold)
    {
        /* Initialize the state. */
        struct wal_writer *writer = &wal_writer_singleton;
        wal_writer_create(writer, wal_mode, wal_dirname,
                          wal_max_size, instance_uuid,
                          on_garbage_collection,
                          on_checkpoint_threshold);
    
        /* Start WAL thread. */
        if (cord_costart(&writer->cord, "wal", wal_writer_f, NULL) != 0)
            return -1;
    
        /* Create a pipe to WAL thread. */
        cpipe_create(&writer->wal_pipe, "wal");
        cpipe_set_max_input(&writer->wal_pipe, IOV_MAX);
        return 0;
    }

The ``writer->cord`` points to the statically allocated
``wal_writer_singleton``. In ``cord_costart`` we start
a new cord. Once the new cord is initialized its event loop
runs ``wal_writer_f``:

.. code-block:: c

    /* box/wal.c */
    static int
    wal_writer_f(va_list ap)
        struct wal_writer *writer = &wal_writer_singleton;

        /* Initialize eio in this thread */
        coio_enable();
    
        // This is new thread and new cord thus we need own fiber scheduler
        struct cbus_endpoint endpoint;
        cbus_endpoint_create(&endpoint, "wal", fiber_schedule_cb, fiber());
    
        // This one is event producer from wal thread to the main thread.
        cpipe_create(&writer->tx_prio_pipe, "tx_prio");
    
        // Enter the event loop
        cbus_loop(&endpoint);
        ...

We're running a new thread with own event loop and a fiber scheduler.
To communicate with this cord and others we use communication bus
(:ref:`cbus`) engine. ``wal`` endpoint, which will be used by other cords
to send messages to the wal thread, and ``writer->tx_prio_pipe``, which
serves as a way for wal thread to communicate with the main tarantool
thread, are created.

.. code-block:: c

    /* box/box.cc */
    box_cfg_xc(void)
        ...
        cbus_endpoint_create(&tx_prio_endpoint, "tx_prio", tx_prio_cb...);

Back to ``wal_writer_f`` code: we enter the event loop ``cbus_loop``
and wait for events to appear (via traditional ``libev`` delivery).

Now back to ``wal_init``. The wal thread is running but we need
to push the messages to it from our side. For this sake we create
a communication pipe (cpipe).

.. code-block:: c

    /* box/wal.c */
    wal_init
        ...
        /* Create a pipe to WAL thread. */
        cpipe_create(&writer->wal_pipe, "wal");

Since endpoint name is ``"wal"`` this cpipe will be nofitying
wal thread.

In summary we have:

  - endpoint ``"tx_prio"`` which listens for events inside
    main tarantool thread;
  - endpoint ``"wal"`` for events inside wal thread;
  - cpipe ``tx_prio_pipe`` to notify main thread from
    inside of wal thread;
  - cpipe ``wal_pipe`` to notify wal thread from
    inside of main thread.

Write data to WAL
~~~~~~~~~~~~~~~~~

When we need to issue a real write we allocate an journal entry
which has a complete set of data to be written in a one pass.

.. code-block:: c

    /* box/journal.h */
    struct journal_entry {
        // To link entries
        struct stailq_entry         fifo;
        // vclock or error code
        int64_t                     res;
        // transaction completions
        journal_write_async_f write_async_cb;
        void *complete_data;
        bool is_complete;
        // real user data to write
        size_t                      approx_len;
        int                         n_rows;
        struct xrow_header          *rows[];
    };

We are not interested in specific data associated with the write
but need to point that entries are chained via ``fifo`` member
and comes in strict order to be able to rollback if something goes
wrong.

Once allocated the entry is passed to

.. code-block:: c

    /* box/wal.c */
    static int
    wal_write_async(struct journal *journal, struct journal_entry *entry)
    {
        ...
        if (!stailq_empty(&writer->wal_pipe.input) &&
            (batch = wal_msg(stailq_first_entry(&writer->wal_pipe.input,
                            struct cmsg, fifo)))) {

            stailq_add_tail_entry(&batch->commit, entry, fifo);
        } else {
            batch = (struct wal_msg *)mempool_alloc(&writer->msg_pool);
            wal_msg_create(batch);
            stailq_add_tail_entry(&batch->commit, entry, fifo);
            cpipe_push(&writer->wal_pipe, &batch->base);
        }
        ...
        cpipe_flush_input(&writer->wal_pipe);
        ...
    }

Here we allocate the communication record (``wal_msg_create``)
then bind journal entry into it, push it into ``writer->wal_pipe``
and notify the producer that there is data to handle. Note that
notification does not mean the data gonna be handled immediately
but get queued into the event loop. The loop here is our main cord
loop (remember as we create ``writer->wal_pipe`` in ``wal_init``).

If the batch already exists in the message queue, which is intended to be
sent to the wal thread, we just add an entry to it.

After that the notification is pushed to the wal thread Once notification
received it runs a callback which has been initialized earlier in
``wal_write_async``:

.. code-block:: c

    /* box/wal.c */
    wal_write_async(struct journal *journal, struct journal_entry *entry)
        ...
        wal_msg_create(batch);
        ...

where:

.. code-block:: c

    /* box/wal.c */
    static struct cmsg_hop wal_request_route[] = {
        {wal_write_to_disk, &wal_writer_singleton.tx_prio_pipe},
        {tx_schedule_commit, NULL},
    };
    
    static void
    wal_msg_create(struct wal_msg *batch)
    {
        cmsg_init(&batch->base, wal_request_route);
        ...
    }


The ``cbus_loop`` inside wal thread wakes
and fetches the message (we're sharing memory between main
tarantool thread and wal thread) and manage that named "route"
functions one by one in direct order.

First the ``wal_write_to_disk`` tries to write journal entries
in a batch to the storage. Actually it does a way more than
simply write to the disk but we're not going to consider it right now.
What is important is that each journal entry gets ``vclock`` value
assigned to the ``journal_entry:res`` member (which is set to
``-1`` on failure).

Once everything is written the ``tx_prio_pipe`` is notified
and then ``tx_schedule_commit`` is running inside main thread.

.. code-block:: c

    /* box/wal.c */
    static void
    tx_schedule_queue(struct stailq *queue)
    {
        struct journal_entry *req, *tmp;
        stailq_foreach_entry_safe(req, tmp, queue, fifo)
            journal_entry_complete(req);
    }
    
    static void
    tx_schedule_commit(struct cmsg *msg)
    {
        struct wal_writer *writer = &wal_writer_singleton;
        struct wal_msg *batch = (struct wal_msg *) msg;
    
        if (!stailq_empty(&batch->rollback)) {
            stailq_concat(&writer->rollback, &batch->rollback);
        }
    
        vclock_copy(&replicaset.vclock, &batch->vclock);
        tx_schedule_queue(&batch->commit);
        mempool_free(&writer->msg_pool, ...);
    }

Here we call a callback associated with journal entry (it is been
assigned during entry allocation we will talk about it later) and
then drop the cbus message back to free pool.

In summary:

  - we notify the wal thread via ``wal_pipe``;
  - wal thread runs ``wal_write_to_disk`` and
    notifies main thread via ``tx_prio_pipe``;
  - main thread runs ``tx_schedule_commit``.

Transactions processing
-----------------------

Transactions processing in 1.x series
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In this series all transactions are processed in synchronous
way. The journal entry carries no callbacks. We allocate the
journal entry and bind the transaction into from inside of
the main cord

.. code-block:: c

    /* box/txn.c */
    struct txn *
    txn_begin(bool is_autocommit)
    {
        static int64_t txn_id = 0;
        struct txn *txn = region_alloc_object(&fiber()->gc, struct txn);
        ...
        txn->id = ++txn_id;
        txn->signature = -1;
        txn->engine = NULL;
        txn->engine_tx = NULL;
        fiber_set_txn(fiber(), txn);
        return txn;
    }

which implies that the fiber which issue the trancaction
must not be freed until the transaction processing is finished.
The ``txn->signature`` is set to ``-1`` pointing that
transaction has not yet been processed (same code is used
in case if transaction has failed though). The ``signature``
is set to vclock upon transaction completion by the wal engine.

.. code-block:: c

    /* box/txn.c */
    int
    txn_commit(struct txn *txn)
    {
        if (txn->engine != NULL) {
            if (engine_prepare(txn->engine, txn) != 0)
                goto fail;
        }
    
        if (txn->n_rows > 0) {
            txn->signature = txn_write_to_wal(txn);
            if (txn->signature < 0)
                goto fail;
        }
        ...
        if (txn->engine != NULL)
            engine_commit(txn->engine, txn);
    
        fiber_gc();
        fiber_set_txn(fiber(), NULL);
        return 0;
    fail:
        txn_rollback();
        return -1;
    }

The key moment here is ``txn_write_to_wal`` function which
sends the transaction to the journal engine, which in turn passes
it to the wal thread.

.. code-block:: c

    /* box/txn.c */
    static int64_t
    txn_write_to_wal(struct txn *txn)
    {
        struct journal_entry *req = journal_entry_new(txn->n_rows);
        ...
        int64_t res = journal_write(req);
        ...
        if (res < 0)
            txn_rollback();
        ...
        return res;
    }


The ``journal_write`` sends to wal thread and what is
important it yields the current fiber. Unlinke 2.x series
there is no callbacks associated with journal entry we just
wake up the fiber which has initiated the transaction (the
fiber initiating the transaction saves pointer to the self
in ``journal_entry`` structure.

.. code-block:: c

    /* box/wal.c */
    // main cord thread
    wal_write
        // notify wal thread about queued data
        cpipe_flush_input(&writer->wal_pipe);
        ...
        bool cancellable = fiber_set_cancellable(false);
        fiber_yield();
        fiber_set_cancellable(cancellable);
        return entry->res;
    
    // wal thread
    wal_write_to_disk
        ...
        // notify main thread
        wal_writer_singleton.tx_prio_pipe
    
    // main thread
    tx_schedule_queue
        stailq_foreach_entry(req, queue, fifo)
            fiber_wakeup(req->fiber);

Thus the transaction is woken up once wal thread finished
processing of the transaction and wrote the entry to the
storage.

Then the fiber from ``wal_write`` is woken up and test
for write result via ``txn->signature`` and either
pass the commit to engine or calls ``txn_rollback``
to rollback the transaction on failure.

Transactions processing in 2.x series
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The transaction processing in 2.x series is almost the same
as in 1.x with one significant exception - journal writes
became asynchronous. We bind callback ``txn_on_journal_write``
to the journal entry which completes the transaction. This
has been done in the sake of parallel applier (which is heavily
used in replication engine).

Thus the ``txn_write`` routine does not wait for transaction
to complete, still for synchronous transactions we wait explicitly
until the journal callback finished

.. code-block:: c

    /* box/txn.c */
    int
    txn_commit(struct txn *txn)
    {
        struct journal_entry *req;
        ...
        req = txn_journal_entry_new(txn);
            /* txn_journal_entry_new code */
            ...
            req = journal_entry_new(txn->n_new_rows + txn->n_applier_rows + 1,
                txn_region, txn_on_journal_write, txn);
        ...
        if (journal_write(req) != 0)
            goto rollback_io;

        ...
    }
