.. _synchronous_replication:

Synchronous replication
=======================

Synchronous replication is the part of Tarantool that makes transactions
wait until they are confirmed by a quorum of replicas. It relies on Raft
for leader election and term tracking (see :ref:`raft`), and adds the
journal-replication machinery on top: the *limbo*, ACK collection and
CONFIRM/ROLLBACK/PROMOTE/DEMOTE records in the WAL.

A transaction touching a space with ``is_sync = true`` is not considered
committed and is not responded to the client until it is replicated onto a
number of replicas configured by ``replication_synchro_quorum``. The master
puts such transactions into the limbo and waits until a quorum of replicas
ACKs the corresponding WAL records; then it writes a CONFIRM record and the
transaction becomes committed. If a quorum can not be collected in time, a
ROLLBACK is written instead.

Limitations of synchronous replication:
 - Master-slave topology: only one node can act as a master and make
   synchronous transactions;
 - Quorum must be at least 50% of the cluster size + 1: using lower
   value for quorum doesn't give any garantees of synchronous
   replication and leads to unexpected problems, such as split-brain.

Election, PreVote, Fencing and split-brain/split-vote detection are
described in :ref:`raft`.

.. note::
   To refresh memory about network connections architecture lets
   put some marks about ``applier`` and ``relay``.

   When replication starts the replica's applier connects to the master node
   where ``iproto`` thread accepts the connection and creates ``relay``
   thread which monitors every new write to the local WAL via WAL watcher
   and replies to the applier on the master node after processing the data.

   Thus each ``applier`` has a corresponding ``relay`` on the remote node. These
   two entities communicate via two separate sockets and each applier
   and relay has a reader and a writer fibers. Also while each ``relay``
   runs as a separate thread and appliers (not exactly one) run in seperate threads
   (the number of threads is controlled by ``replication_threads`` option).

   For details see :ref:`replication` and ':ref:`relay` internal docs.

Since our WAL engine is **append only** two new records are added:
``IPROTO_RAFT_CONFIRM`` and ``IPROTO_RAFT_ROLLBACK``. The first one means
that replicas have successfully written a transaction and we can
continue handling new ones. In turn rollback implies that a quorum
has not been achieved and the transaction should be discarded.

Limbo
~~~~~

Most important structure in synchronous replication is ``limbo``, which is used to
track synchronous transactions status. Transactions, which are not commited
nor rolled back (it means that they are in progress of collecting ACKs)
are stored here. It is defined as:

.. code-block:: c

    struct txn_limbo {
        /** Limbo state: INACTIVE, LEADER or REPLICA. */
        enum txn_limbo_state state;
        /** Synchronous transactions and other ones depending on them. */
        struct txn_limbo_queue queue;
        /**
         * Latest terms received with PROMOTE entries from remote instances.
         * Limbo uses them to filter out the transactions coming not from the
         * limbo owner.
         */
        struct vclock promote_term_map;
        /**
         * The biggest PROMOTE term seen by the instance and persisted in WAL.
         */
        uint64_t term;
        /** To linearize any sort of state changes. */
        struct latch state_latch;
        /** Whether the limbo is in rollback mode. */
        bool is_in_rollback;
        /** If there is an ongoing PROMOTE being applied. */
        bool is_transition_in_progress;
        /** If the limbo is being recovered right now. */
        bool is_in_recovery;
        /** If the limbo has seen a fresh promote after recovery. */
        bool saw_promote;
        /**
         * Savepoint of confirmed LSN. To rollback to in case the current
         * synchro command (promote/demote/...) fails.
         */
        int64_t svp_confirmed_lsn;
        /**
         * Whether this instance validates incoming synchro requests. When the
         * setting is on, the instance only allows CONFIRM/ROLLBACK from the
         * limbo owner, tracks PROMOTE/DEMOTE term and owner_id consistency.
         * The filtering is turned off during bootstrap.
         */
        bool do_validate;
        /** The elections state machine controlling the limbo. */
        struct raft *raft;
        /** Asynchronously writes CONFIRM requests to the WAL. */
        struct fiber *worker;
        /** A trigger invoked on replica acks. */
        struct trigger on_ack;
    };

The queue itself was extracted into a separate ``struct txn_limbo_queue``
(``src/box/txn_limbo_queue.h``), which owns ``owner_id``, the ``entries``
list, ``len``, ``confirmed_lsn``, ``volatile_confirmed_lsn`` and the ACK
vclock. The current limbo state is tracked by ``enum txn_limbo_state``
(``TXN_LIMBO_STATE_INACTIVE``, ``TXN_LIMBO_STATE_LEADER``,
``TXN_LIMBO_STATE_REPLICA``). The old ``frozen_reasons`` flags are gone.


Master initiates transaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Let's consider the case where a transaction is initiated on a master
node and replicated to the single replica. Before entering limbo the record
goes via:

.. code-block:: c

    txn_commit
        txn_journal_entry_new

The ``txn_journal_entry_new`` traverse the rows in the record and
if there is a synchronous space modified then we do

.. code-block:: c

    txn_journal_entry_new
        ...
        if (is_sync) {
            txn_set_flags(txn, TXN_WAIT_SYNC | TXN_WAIT_ACK);
        } else if (!txn_limbo_is_empty(&txn_limbo)) {
            txn_set_flags(txn, TXN_WAIT_SYNC);
        }

So we mark the transaction with ``TXN_WAIT_SYNC | TXN_WAIT_ACK``
flags, ie the transaction should wait until previous transactions
are complete and receive ACKs from a quorum.

Note that if the transaction is asynchronous but the limbo queue is
not empty, it means that there are some previous uncommitted synchronous
transactions on the fly, and this asynchronous transaction should wait
for previous synchronous transactions to complete first, thus we mark
such transaction as ``TXN_WAIT_SYNC``.

Then we add the transaction to the limbo:

.. code-block:: c

    txn_commit
        req = txn_journal_entry_new(txn);
        ...
        if (txn_has_flag(txn, TXN_WAIT_SYNC) &&
            txn_add_limbo_entry(txn, req) != 0) {
            goto rollback_abort;
        }

.. code-block:: c

    txn_add_limbo_entry
        uint32_t origin_id = req->rows[0]->replica_id;
        txn_limbo_submit(&txn_limbo, origin_id, txn, req->approx_len);

The ``txn_limbo_submit`` allocates a new limbo entry which is defined as

.. code-block:: c

    struct txn_limbo_entry {
        /** Link for the entry queue. */
        struct rlist in_queue;
        /** Transaction, waiting for a quorum. */
        struct txn *txn;
        /** Approximate size of this request when encoded. */
        size_t approx_len;
        /**
         * LSN of the transaction by the originator's vclock
         * component. May be -1 in case the transaction is not
         * written to WAL yet.
         */
        int64_t lsn;
        /** State of this entry. */
        enum txn_limbo_entry_state state;
        /** When this entry was added to the queue. */
        double insertion_time;
    };

Note that the per-entry ACK counter and the ``is_commit``/``is_rollback``
flags are gone. The ACK count is now tracked by the queue
(``txn_limbo_queue.ack_count``), and the entry state is represented by
``enum txn_limbo_entry_state`` (``TXN_LIMBO_ENTRY_VOLATILE``,
``TXN_LIMBO_ENTRY_SUBMITTED``, ``TXN_LIMBO_ENTRY_COMMIT``,
``TXN_LIMBO_ENTRY_ROLLBACK``).

Then this limbo entry is appended to the ``txn_limbo.queue.entries`` list.
It is very important that entries are appended to the list, which
allows to determinate aging of entries.

Once limbo entry is allocated and queued we write the transaction
to the storage device:

.. code-block:: c

    txn_commit
        req = txn_journal_entry_new(txn);
        ...
        if (txn_has_flag(txn, TXN_WAIT_SYNC) &&
            txn_add_limbo_entry(txn, req, TXN_COMMIT_WAIT_MODE_COMPLETE) != 0) {
            goto rollback_abort;
        }
        ...
        if (journal_write_submit(req) != 0)
            goto rollback_io;

The write is synchronous here, so we are waiting for it to be complete (in
case of an error we simply drop this entry from the limbo).

An interesting moment is that when WAL thread finishes writing it notifies
WAL watcher (that is, the relay thread) that new data has been appended to the journal.
The relay watcher performs ``recover_remaining_wals`` and sends new data
to the replica.

Replica receives transaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Processing remote transactions goes via ``applier`` module. So let's assume
we obtain a new synchronous record from the master node above and master
WAL thread finished write procedure but we have not yet returned from
``journal_write`` in terms of fiber switching.

Decoding incoming replication stream is done in seperate thread in applier
with ``applier_thread_reader_f`` function, which pushes decoded messages
to tx. Tx thread on its side applies them with ``applier_process_batch`` function:

.. code-block:: c

    applier_process_batch:
        ...
        applier_apply_tx
            ...
            if (unlikely(iproto_type_is_synchro_request(first_row->type))) {
                rc = apply_synchro_req(applier->instance_id, &txr->row, &txr->req.synchro);
                    ...
                    journal_entry_create(&entry.base, 1, xrow_approx_len(row),
                                         apply_synchro_req_cb, &entry);
                    ...
                    txn_limbo_begin(&txn_limbo);
                    if (txn_limbo_req_prepare(&txn_limbo, req) < 0)
                        goto err;
                    if (journal_write(&entry.base) != 0) {
                        txn_limbo_req_rollback(&txn_limbo, req);
                        goto err;
                    }
                    if (entry.base.res < 0) {
                        diag_set_journal_res(entry.base.res);
                        goto err;
                    }

                    txn_limbo_commit(&txn_limbo);
            } else {
                rc = apply_plain_tx(applier->instance_id, rows);
            }

The ``journal_write`` writes data to the storage device in synchronous way.
When write finishes, ``txn_on_journal_write`` is called, which assigns
``lsn`` from the master node to the limbo entry:

.. code-block:: c

    txn_on_journal_write
        ...
        if (!txn_has_flag(txn, TXN_WAIT_SYNC)) {
            txn_complete_success(txn);
        } else {
            int64_t lsn;
            ...
            txn_limbo_assign_lsn(&txn_limbo, ack_origin_id,
                                 txn->limbo_entry, lsn);
        }

``apply_synchro_req`` adds a callback ``apply_synchro_req_cb``, which runs
``applier_on_wal_write``:

.. code-block:: c

    static int
    applier_on_wal_write(struct trigger *trigger, void *event)
    {
        struct applier *applier = (struct applier *)trigger->data;
        applier_signal_ack(applier);
        applier_check_sync(applier);
        return 0;
    }

This cause ``applier_thread_writer_f`` fiber, which runs in the applier thread,
to write ACK message to the master's relay reader.

Master WAL write of the transaction data can complete with any speed in any
order with the ACKs receipt. So, we assume that all of this happens before
the master node wakes up from its own write operation.

Master receives ACK
~~~~~~~~~~~~~~~~~~~

The master's node relay reader ``relay_reader_f`` receives ACK message
which is basically LSN of the data been written. Thus the data has been
just written on the replica.

.. code-block:: c

    int
    relay_reader_f(va_list ap)
    {
        ...
        struct applier_heartbeat *last_recv_ack = &relay->last_recv_ack;
        ...
        xrow_decode_applier_heartbeat_xc(&xrow, last_recv_ack);
        ...
    }

Then main relay fiber detects that replica has received the data.

.. code-block:: c

    static void
    relay_check_status_needs_update(struct relay *relay)
    {
        struct applier_heartbeat *last_recv_ack = &relay->last_recv_ack;
        struct relay_status_msg *status_msg = &relay->status_msg;
        ...
        if (relay->version_id < version_id(1, 7, 4))
            send_vclock = &relay->r->vclock;
        else
            send_vclock = &last_recv_ack->vclock;
        ...
        if (vclock_sum(&status_msg->vclock) ==
            vclock_sum(send_vclock))
            return;

        static const struct cmsg_hop route[] = {
            {tx_status_update, NULL}
        };
        cmsg_init(&status_msg->msg, route);
        vclock_copy_ignore0(&status_msg->vclock, send_vclock);
        ...
        cpipe_push(&relay->tx_pipe, &status_msg->msg);
    }

This causes ``tx_status_update`` to run in the context of ``tx`` thread,
remember the relay runs in a separate thread. The ``tx_status_update`` tries
to update limbo status

.. code-block:: c

    static void
    tx_status_update(struct cmsg *msg)
    {
        struct relay_status_msg *status = (struct relay_status_msg *)msg;
        ...
        struct replication_ack ack;
        ack.source = status->relay->replica->id;
        ack.vclock = &status->vclock;
        ack.vclock_sync = status->vclock_sync;
        ...
        raft_process_term(box_raft(), status->term, ack.source);
        if (!anon && ack.source != REPLICA_ID_NIL)
            trigger_run(&replicaset.on_ack, &ack);
        ...
    }

Instead of calling ``txn_limbo_ack`` directly, ``tx_status_update`` runs the
``replicaset.on_ack`` trigger. The limbo registers ``txn_limbo.on_ack`` which
turns an ACK into a queue update:

.. code-block:: c

    static int
    txn_limbo_on_ack_f(struct trigger *t, void *event)
    {
        struct txn_limbo *limbo = t->data;
        const struct replication_ack *ack = event;
        int64_t lsn = vclock_get(ack->vclock, limbo->queue.owner_id);
        txn_limbo_ack(limbo, ack->source, lsn);
        return 0;
    }

Here is a very interesting moment: the purpose of ``txn_limbo_ack`` is to
gather ACKs on synchronous replication to obtain quorum. It is now a thin
wrapper around the queue, which asynchronously wakes the CONFIRM worker:

.. code-block:: c

    static void
    txn_limbo_ack(struct txn_limbo *limbo, uint32_t replica_id, int64_t lsn)
    {
        if (txn_limbo_queue_ack(&limbo->queue, replica_id, lsn))
            fiber_wakeup(limbo->worker);
    }

The queue-level ACK bumps the *volatile* confirmed LSN in
``txn_limbo_queue_ack()``; the actual CONFIRM record is then written by the
worker fiber ``txn_limbo_worker_f`` (see below). The key moment for our
scenario is setting the LSN from the replica in ``limbo->queue.vclock``,
then since the LSN on the entry has not yet been assigned the ACK has no
effect yet.

Master finishes write
~~~~~~~~~~~~~~~~~~~~~

Now let's continue. Assume that we've finally been woken up from the
``journal_write`` and entry is in limbo with ``lsn = -1``. When write finishes,
``txn_on_journal_write`` is called:

.. code-block:: c

    txn_on_journal_write(struct journal_entry *entry)
        ...
        txn_limbo_assign_lsn(&txn_limbo, ack_origin_id,
                             txn->limbo_entry, lsn);

First, we fetch the LSN assigned by the WAL engine and call
``txn_limbo_assign_lsn``, which assigns the entry and accounts for the ACKs
already collected. The per-entry ``ack_count`` is gone: ACKs are now tracked
by the queue and recomputed from ``limbo->queue.vclock``.

.. code-block:: c

    void
    txn_limbo_assign_lsn(struct txn_limbo *limbo, uint32_t origin_id,
                         struct txn_limbo_entry *entry, int64_t lsn)
    {
        txn_limbo_queue_assign_lsn(&limbo->queue, entry, lsn);
        txn_limbo_ack(limbo, origin_id, lsn);
    }

In our case the relay has been updating ``limbo->queue.vclock`` before we
exit the WAL write routine, so the replica already wrote this new data to
its own WAL and we can detect this situation.

Then we call ``txn_limbo_ack`` by ourselves (because we wrote the data to
our own WAL and can ACK it). This time the entry has an LSN assigned, so the
queue-level ACK reaches the quorum and bumps the *volatile* confirmed LSN.

In our scenario we have only one master and one slave node so we just reached
the replication quorum thus we need to inform all nodes that the quorum is
collected and we are safe to proceed.

For this sake the CONFIRM worker writes an ``IPROTO_RAFT_CONFIRM`` record to
our WAL; the record carries ``confirmed_lsn``:

.. code-block:: c

    static int
    txn_limbo_worker_bump_confirmed_lsn(struct txn_limbo *limbo)
    {
        struct txn_limbo_queue *queue = &limbo->queue;
        while (limbo->state == TXN_LIMBO_STATE_LEADER &&
               queue->volatile_confirmed_lsn > queue->confirmed_lsn) {
            ...
            int64_t lsn = queue->volatile_confirmed_lsn;
            if (txn_limbo_write_confirm(limbo, lsn) != 0)
                return -1;
            txn_limbo_queue_apply_confirm(queue, lsn);
        }
        return 0;
    }

The write is synchronous so we wait until it completes. Once written it is
propagated to the replica via the ``master relay -> replica applier`` socket.
When the replica receives this packet it calls ``apply_synchro_req`` which
writes it to the replica WAL. Note that here we can reach the same scenario
as for a regular write -- the master relay receives an ACK from the replica's
``IPROTO_RAFT_CONFIRM`` write, but the entry's LSN is less than the LSN of
the CONFIRM record so we won't do anything.

The queue-level confirm is applied by ``txn_limbo_queue_apply_confirm``:

.. code-block:: c

    static void
    txn_limbo_queue_apply_confirm(struct txn_limbo_queue *queue, int64_t lsn)
    {
        struct txn_limbo_entry *e, *tmp;

        rlist_foreach_entry_safe(e, &queue->entries, in_queue, tmp) {
            ...
            e->state = TXN_LIMBO_ENTRY_COMMIT;
            txn_complete_success(e->txn);
            ...
        }
    }

Here we traverse the queue and mark the entries as committed and discard
them from the queue.

Finally, the master node calls ``txn_limbo_wait_complete``:

.. code-block:: c

    enum txn_limbo_wait_entry_result
    txn_limbo_wait_complete(struct txn_limbo *limbo,
                            struct txn_limbo_entry *entry)
    {
        ...
    }

In our scenario the relay and replica were so fast that
``txn_limbo_queue_apply_confirm`` already collected the quorum and finished
processing of synchronous replication but this is not always happen this way.

In turn the replica may do the reverse and due to various reasons
(for example network lag) and decelerate the processing. Thus
the master node gonna wait until replica processes the data.

And for this case ``txn_limbo_wait_complete`` tries its best.
Let's consider this early write case below.

Master write finished early
~~~~~~~~~~~~~~~~~~~~~~~~~~~

We assume the WAL wrote the data and entry in limbo is assigned with a
proper LSN number. Relay has sent this new data to the salve's node
applier already.

.. code-block:: c

    enum txn_limbo_wait_entry_result
    txn_limbo_wait_complete(struct txn_limbo *limbo,
                            struct txn_limbo_entry *entry)
    {
        enum txn_limbo_wait_entry_result rc =
            txn_limbo_queue_wait_complete(&limbo->queue, entry);
        if (rc != TXN_LIMBO_WAIT_ENTRY_NEED_ROLLBACK)
            return rc;
        ...
        txn_limbo_write_rollback(limbo, entry->lsn);
        txn_limbo_queue_apply_rollback(&limbo->queue, entry->lsn,
                                       TXN_SIGNATURE_QUORUM_TIMEOUT);
        diag_set(ClientError, ER_SYNC_QUORUM_TIMEOUT);
        return TXN_LIMBO_WAIT_ENTRY_FAIL_COMPLETE;
    }

The wait itself is performed by the queue-level
``txn_limbo_queue_wait_complete``, which returns
``enum txn_limbo_wait_entry_result``. When
``replication_synchro_timeout_rollback_enabled`` is off it uses
``txn_synchro_timeout`` and detaches the transaction
(``TXN_LIMBO_WAIT_ENTRY_FAIL_DETACH``) instead of rolling it back; rollback
by timeout is a legacy behavior that is being removed.

First, we check for the previous scenario where the relay has already replied
that the replica received and confirmed the data. But we're interested
in the next case where the replica didn't process the new data yet.

So we start waiting for a configurable timeout. This puts us to a wait
cycle where other fibers and threads continue working.
In particular, while we're in ``fiber_cond_wait_timeout``,
the replica obtains new data, writes it to its own WAL,
then our master's relay acquires ratification, and then runs
``tx_status_update`` and ``txn_limbo_ack``, which in turn initiate the already
known ``txn_limbo_write_confirm`` and ``txn_limbo_queue_apply_confirm`` calls
sequence. The ``IPROTO_RAFT_CONFIRM`` get written on the master node and
propagated to the replica node then.

Rollback
~~~~~~~~

However, if timeout passes and the limbo entry is still not complete,
``txn_limbo_write_rollback`` is called:

.. code-block:: c

    static void
    txn_limbo_write_rollback(struct txn_limbo *limbo, int64_t lsn)
    {
        assert(lsn > limbo->queue.confirmed_lsn);
        assert(!limbo->is_in_rollback);
        limbo->is_in_rollback = true;
        struct synchro_request req = {
            .type = IPROTO_RAFT_ROLLBACK,
            .queue_owner_id = limbo->queue.owner_id,
            .rollback = {
                .lsn = lsn
            },
        };
        synchro_request_write_or_panic(&req);
        limbo->is_in_rollback = false;
    }

It writes a rollback message to WAL. After it's written all the transactions
following the current one and waiting for confirmation will be rolled back.

Wal stream is processed by ``wal_stream_apply_row`` function. As we write
synchronously, ``wal_stream_apply_synchro_row``` is called:

.. code-block:: c

    static void
    wal_stream_create(struct wal_stream *ctx)
    {
        xstream_create(&ctx->base, wal_stream_apply_row,
                   wal_stream_schedule_yield);
        lsregion_create(&ctx->lsr, &runtime);
        for (int i = 0; i < VCLOCK_MAX; i++)
            rlist_create(&ctx->nodes_rows[i]);
        ctx->tsn = 0;
        ctx->first_row_lsn = 0;
        ctx->has_yield = false;
        ctx->has_global_row = false;
    }

.. code-block:: c

    static void
    wal_stream_apply_row(struct xstream *base, struct xrow_header *row)
    {
        struct wal_stream *stream =
            container_of(base, struct wal_stream, base);
        if (iproto_type_is_synchro_request(row->type)) {
            if (wal_stream_apply_synchro_row(stream, row) != 0)
                goto end_error;
        } else if (iproto_type_is_raft_request(row->type)) {
            if (wal_stream_apply_raft_row(stream, row) != 0)
                goto end_error;
        } else if (box_is_force_recovery) {
            if (wal_stream_apply_mixed_dml_row(stream, row) != 0)
                goto end_error;
        } else if (wal_stream_apply_dml_row(stream, row) != 0) {
            goto end_error;
        }
        ...
    }

``wal_stream_apply_synchro_row`` decodes the request and passes it to
``txn_limbo_process``:

.. code-block:: c

    static int
    wal_stream_apply_synchro_row(struct wal_stream *stream,
                                 struct xrow_header *row)
    {
        ...
        struct synchro_request syn_req;
        if (xrow_decode_synchro(row, &syn_req) != 0)
            return -1;
        if (journal_write_row(row) != 0)
            return -1;
        return txn_limbo_process(&txn_limbo, &syn_req);
    }

``txn_limbo_req_commit`` processes a synchronous replication request and
initiates reading confirm, rollback, promote or demote:

.. code-block:: c

    void
    txn_limbo_req_commit(struct txn_limbo *limbo, const struct synchro_request *req)
    {
        switch (req->type) {
        case IPROTO_RAFT_CONFIRM:
            txn_limbo_req_commit_confirm(limbo, req);
            return;
        case IPROTO_RAFT_ROLLBACK:
            txn_limbo_req_commit_rollback(limbo, req);
            return;
        }
        txn_limbo_req_commit_promote_demote(limbo, req);
    }

The queue-level rollback is applied by ``txn_limbo_queue_apply_rollback``,
which deletes transactions from the limbo queue.

