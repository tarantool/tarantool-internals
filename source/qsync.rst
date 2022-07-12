Qsync
=====

Introduction
------------

``Qsync`` stands for quorum-based synchronous replication. In
short it means that every record should be confirmed by a number
of replicas (quorum) before the record is considered to be safe to
proceed.

Since our WAL engine is **append only** two new records are added:
``IPROTO_CONFIRM`` and ``IPROTO_ROLLBACK``. The first one means
that replicas have successfully written a transaction and we can
continue handling new ones. In turn rollback implies that a quorum
has not been achieved and the transaction should be discarded.
To track transactions status we use that named ``limbo`` engine.

Worth to note some limitations in ``qsync`` implementation:

 - only **one** master node is supported within a cluster;
 - quorum should fit the ``N/2+1`` formula, where ``N``
   is a number of replicas in a cluster.

To refresh memory about network connections architecture lets
put some marks about ``applier`` and ``relay``. When replication
starts the applier connects to the replica node where ``iproto``
thread accepts the connection and creates ``relay`` thread which
monitors every new write to the local WAL via WAL watcher and
replies to the applier on the master node after processing the data.
In reverse the slave node raises its own ``applier`` and the master
setup ``relay`` to send new data to the slave node. Thus each
``applier`` has a corresponding ``relay`` on the remote node. These
two entities communicate via two separate sockets and each applier
and relay has a reader and a writer fibers. Also while each ``relay``
runs as a separate thread the appliers on the node are spinning
in one ``tx`` thread as fibers.

Quorum based synchronous replication
------------------------------------

Most important structure in ``qsync`` is that named ``limbo``,
which is defined as

.. code-block:: c

    struct txn_limbo {
        struct rlist        queue;
        int64_t             len;
        uint32_t            owner_id;
        struct fiber_cond   wait_cond;
        struct vclock       vclock;
        int64_t             confirmed_lsn;
        int64_t             rollback_count;
        bool                is_in_rollback;
    };

Where
 - ``queue`` is a list of pending transactions waiting for
   a quorum, new transactions are appended to the list so
   the rightmost is the oldest transaction;
 - ``len`` is for statistics and tracks the current number
   of pending transactions;
 - ``owner_id`` limbo owner, ie transaction initiator, there
   can be only one limbo owner at a time;
 - ``wait_cond`` (**FIXME**);
 - ``confirmed_lsn`` (**FIXME**);
 - ``rollback_count`` is for rollback statistics, ie number of
   rolled back transactions;
 - ``is_in_rollback`` a flag to mark if limbo is currently rolling
   back a transaction.

Let's consider the case where a transaction is initiated on a master
node and replicated to the single replica.

Master initiates transaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Before entering limbo the record goes via

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

Note though if the transaction is asynchronous but the limbo queue is
not empty means that there are some previous uncommitted synchronous
transactions on the fly, and this asynchronous transaction should wait
for previous synchronous transactions to complete first, thus we mark
such transaction as ``TXN_WAIT_SYNC``.

Then we add the transaction to the limbo:


.. code-block:: c

    txn_commit
        txn_journal_entry_new
        ...
        if (txn_has_flag(txn, TXN_WAIT_SYNC)) {
            uint32_t origin_id = req->rows[0]->replica_id;
            limbo_entry = txn_limbo_append(&txn_limbo, origin_id, txn);
         }

The ``txn_limbo_append`` allocates a new limbo entry which is defined as


.. code-block:: c

    struct txn_limbo_entry {
        struct rlist        in_queue;
        struct txn          *txn;
        int64_t             lsn;
        int                 ack_count;
        bool                is_commit;
        bool                is_rollback;
    };

Where
 - ``in_queue`` is link for ``txn_limbo::queue``;
 - ``txn`` a transaction associated with the entry;
 - ``lsn`` transaction LSN number, set to particular number
   when the transaction is written to WAL;
 - ``ack_count`` number of ACKs accounted for quorum sake;
 - ``is_commit`` set when entry is committed;
 - ``is_rollback`` set when entry is rolled back;

Then this limbo entry is appended to the ``txn_limbo::queue`` list.
It is very important that entries are appended to the list and
allows to determinate aging of entries.

Once limbo entry is allocated and queued we write the transaction
to the storage device.

.. code-block:: c

    txn_commit
        txn_journal_entry_new
        ...
        if (txn_has_flag(txn, TXN_WAIT_SYNC)) {
            uint32_t origin_id = req->rows[0]->replica_id;
            limbo_entry = txn_limbo_append(&txn_limbo, origin_id, txn);
         }
        ...
        if (journal_write(req) != 0 || req->res < 0) {
            if (is_sync)
                txn_limbo_abort(&txn_limbo, limbo_entry);
            ...
        }

The write is synchronous here, so we are waiting for it to be complete (in
case of an error we simply drop this entry from the limbo).

An interesting moment is that when WAL thread finishes writing it notifies
WAL watcher (ie relay thread) that new data has been appended to the journal.
The relay watcher performs ``recover_remaining_wals`` and sends new data
to the replica.

Replica receives transaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Processing remote transactions goes via ``applier`` module. So let's assume
we obtain a new synchronous record from the master node above and master
has not finished write procedure yet in terms of fiber switching, thus
we have not yet returned from ``journal_write``. The replica does

.. code-block:: c

    applier_subscribe
        ...
        applier_read_tx
        ...
        applier_apply_tx
            ...
            apply_plain_tx
                txn = txn_begin();
                trigger_create(applier_txn_rollback_cb)
                trigger_create(applier_txn_wal_write_cb)
            txn_commit_try_async

It is very important that ``apply_plain_tx`` allocates the transaction
(ie calls ``txn = txn_begin()``) before calling ``txn_commit_try_async``.
This allows us to not call ``txn_commit`` on replica node because
``txn_commit`` is for commit initiator only and in terms of quorum
synchronisation should be called on a master node.

Similarly to ``txn_commt`` the ``txn_commit_try_async`` allocates a new
limbo entry and queues it.

.. code-block:: c

    void
    txn_commit_try_async(struct txn *txn) {
        ...
        req = txn_journal_entry_new(txn);
        bool is_sync = txn_has_flag(txn, TXN_WAIT_SYNC);
        struct txn_limbo_entry *limbo_entry;
        if (is_sync) {
            limbo_entry = txn_limbo_append(&txn_limbo, origin_id, txn);
            if (txn_has_flag(txn, TXN_WAIT_ACK)) {
                int64_t lsn = req->rows[txn->n_applier_rows - 1]->lsn;
                txn_limbo_assign_lsn(&txn_limbo, limbo_entry, lsn);
            }
        }
        if (journal_write_try_async(req) != 0) {
            ...
        }

The ``journal_write_try_async`` writes data to the storage device in
asynchronous way, ie the code does not wait for it to be complete before
processing new requests from applier. But for our scenario we assume that this
write happens so fast that it completes before the master node is waking up from
its own write operation.

So the ``txn_limbo_assign_lsn`` above assigns ``lsn`` from the master node
to the limbo entry and then WAL write finishes and calls
``applier_txn_wal_write_cb`` callback, which in turn causes
``applier_on_wal_write`` to run

.. code-block:: c

    static int
    applier_on_wal_write(struct trigger *trigger, void *event)
    {
        struct applier *applier = (struct applier *)trigger->data;
        applier_signal_ack(applier);
        return 0;
    }

This cause ``applier_writer_f`` fiber on replica to write ACK message
to the master's relay reader.

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
        xrow_decode_vclock_xc(&xrow, &relay->recv_vclock);
        ...
    }

Then main relay fiber detects that replica has received the data.

.. code-block:: c

    static int
    relay_subscribe_f(va_list ap)
    {
        while (!fiber_is_cancelled()) {
            ...
            send_vclock = &relay->recv_vclock;
            ...
            if (vclock_sum(&relay->status_msg.vclock) ==
                vclock_sum(send_vclock))
                continue;
            static const struct cmsg_hop route[] = {
                {tx_status_update, NULL}
            }
            cmsg_init(&relay->status_msg.msg, route);
            vclock_copy(&relay->status_msg.vclock, send_vclock);
            relay->status_msg.relay = relay;
            cpipe_push(&relay->tx_pipe, &relay->status_msg.msg);
            ...
    }

This causes ``tx_status_update`` to run in the context of ``tx`` thread,
remember the relay runs in a separate thread. Since we assume that
master is still sitting in ``journal_write`` then the ``tx_status_update``
may run before ``journal_write`` finishes. The ``tx_status_update`` tries
to update limbo status

.. code-block:: c

    static void
    tx_status_update(struct cmsg *msg)
    {
        ...
        if (txn_limbo.owner_id == instance_id) {
            txn_limbo_ack(&txn_limbo, ack.source,
                          vclock_get(ack.vclock, instance_id));
        }
        ...
    }

And here is a very interesting moment, the ``txn_limbo_ack`` purpose is to
gather ACKs on synchronous replication to obtain quorum.

.. code-block:: c

    void
    txn_limbo_ack(struct txn_limbo *limbo, uint32_t replica_id, int64_t lsn)
    {
        /* Nothing to ACK */
        if (rlist_empty(&limbo->queue))
            return;

        /* Ignore if we're rolling back already */
        if (limbo->is_in_rollback)
            return;

        int64_t prev_lsn = vclock_get(&limbo->vclock, replica_id);
        if (lsn == prev_lsn)
            return;

        /* Mark ACK'ed lsn */
        vclock_follow(&limbo->vclock, replica_id, lsn);

        struct txn_limbo_entry *e;
        int64_t confirm_lsn = -1;

        rlist_foreach_entry(e, &limbo->queue, in_queue) {
            if (e->lsn > lsn)
                break;
            if (!txn_has_flag(e->txn, TXN_WAIT_ACK)) {
                continue;
            } else if (e->lsn <= prev_lsn) {
                continue;
            } else if (++e->ack_count < replication_synchro_quorum) {
                continue;
            } else {
                confirm_lsn = e->lsn;
            }
        }

        if (confirm_lsn == -1 || confirm_lsn <= limbo->confirmed_lsn)
            return;

        txn_limbo_write_confirm(limbo, confirm_lsn);
        txn_limbo_read_confirm(limbo, confirm_lsn);
    }

The key moment for our scenario is setting the LSN from replica in
``limbo->vclock``, then since LSN on entry has not yet been assigned we
exit early.

Master finishes write
~~~~~~~~~~~~~~~~~~~~~

Now let's continue. Assume that we've finally been woken up from the
``journal_write`` and entry is in limbo with ``lsn = -1``.

.. code-block:: c

    int
    txn_commit(struct txn *txn)
    {
        ...
        if (is_sync) {
            if (txn_has_flag(txn, TXN_WAIT_ACK)) {
                int64_t lsn = req->rows[req->n_rows - 1]->lsn;
                txn_limbo_assign_local_lsn(&txn_limbo, limbo_entry, lsn);
                txn_limbo_ack(&txn_limbo, txn_limbo.owner_id, lsn);
            }
            if (txn_limbo_wait_complete(&txn_limbo, limbo_entry) < 0)
                goto rollback;
        }

First, we fetch LSN assigned by WAL engine and call ``txn_limbo_assign_local_lsn``,
which not only assigns the entry but also collects the number of ACKs obtained.

.. code-block:: c

    void
    txn_limbo_assign_local_lsn(struct txn_limbo *limbo,
                               struct txn_limbo_entry *entry,
                               int64_t lsn)
    {
        /* WAL provided us this number */
        entry->lsn = lsn;
    
        struct vclock_iterator iter;
        vclock_iterator_init(&iter, &limbo->vclock);

        /*
         * In case if relay is faster than tx the ACK
         * may have came already from remote node and
         * our relay set LSN here so lets account it.
         */
        int ack_count = 0;
        vclock_foreach(&iter, vc)
            ack_count += vc.lsn >= lsn;
    
        entry->ack_count = ack_count;
    }

In our case the relay has been updating ``limbo->vclock`` before we exit WAL
write routine so the replica already wrote this new data to an own WAL and
now we can detect this situation by reading replica ACK from ``entry->ack_count``.

Then we call ``txn_limbo_ack`` by ourselves (because we wrote the data to the
own WAL and can ACK it), but this time entry has LSN assigned so we walk
over the limbo queue and this time we reach the quorum so that ``confirm_lsn``
points to our entry.

In our scenario we have only one master and one slave node so we just reached the
replication quorum thus we need to inform all nodes that the quorum is collected
and we are safe to proceed.

For this sake we call ``txn_limbo_write_confirm`` which writes ``IPROTO_CONFIRM``
record to our WAL, this record consists of ``confirmed_lsn``.

.. code-block:: c

    static void
    txn_limbo_write_confirm(struct txn_limbo *limbo, int64_t lsn)
    {
        limbo->confirmed_lsn = lsn;
        txn_limbo_write_synchro(limbo, IPROTO_CONFIRM, lsn);
    }


The write is synchronous so we wait until it completes. Once written it propagated
to the replica via ``master relay -> replica applier`` socket. When replica
receives this packet it calls ``apply_synchro_row`` which writes this packet to
the replica WAL. Note that here we can reach the same scenario as for a regular
write -- the master relay receives ACK from replica's ``IPROTO_CONFIRM`` write
but entry's LSN gonna be less than LSN of ``IPROTO_CONFIRM`` record so we won't
do anything.

Then master runs ``txn_limbo_read_confirm``.

.. code-block:: c

    static void
    txn_limbo_read_confirm(struct txn_limbo *limbo, int64_t lsn)
    {
        struct txn_limbo_entry *e, *tmp;

        rlist_foreach_entry_safe(e, &limbo->queue, in_queue, tmp) {
            if (txn_has_flag(e->txn, TXN_WAIT_ACK)) {
                if (e->lsn > lsn)
                    break;
                if (e->lsn == -1)
                    break;
            }

            e->is_commit = true;
            txn_limbo_remove(limbo, e);
            txn_clear_flags(e->txn, TXN_WAIT_SYNC | TXN_WAIT_ACK);

            txn_complete_success(e->txn);
        }
    }

Here we traverse the queue and mark the entry as committed and discard
it from the queue.

Finally, the master node exits from ``txn_limbo_ack`` and calls
``txn_limbo_wait_complete``. In our scenario the relay and replica
were so fast that ``txn_limbo_read_confirm`` already collected the
quorum and finished processing of synchronous replication but this
is not always happen this way.

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

    int
    txn_limbo_wait_complete(struct txn_limbo *limbo, struct txn_limbo_entry *entry)
    {
        bool cancellable = fiber_set_cancellable(false);
    
        /*
         * Replicas already confirmed this entry and
         * CONFIRM is written in our wal.
         */
        if (txn_limbo_entry_is_complete(entry))
            goto complete;
        
        double start_time = fiber_clock();
        while (true) {
            double deadline = start_time + replication_synchro_timeout;
            double timeout = deadline - fiber_clock();

            int rc = fiber_cond_wait_timeout(&limbo->wait_cond, timeout);

            /*
             * It get confirmed by all replicas via relay.
             */
            if (txn_limbo_entry_is_complete(entry))
                goto complete;

            if (rc != 0)
                break;
        }
    
        if (txn_limbo_first_entry(limbo) != entry)
            goto wait;
    
        if (entry->lsn <= limbo->confirmed_lsn)
            goto wait;
    
        txn_limbo_write_rollback(limbo, entry->lsn);

        struct txn_limbo_entry *e, *tmp;
        rlist_foreach_entry_safe_reverse(e, &limbo->queue, in_queue, tmp) {
            e->txn->signature = TXN_SIGNATURE_QUORUM_TIMEOUT;
            txn_limbo_abort(limbo, e);
            txn_clear_flags(e->txn, TXN_WAIT_SYNC | TXN_WAIT_ACK);
            txn_complete_fail(e->txn);
            if (e == entry)
                break;
            fiber_wakeup(e->txn->fiber);
        }
        fiber_set_cancellable(cancellable);
        diag_set(ClientError, ER_SYNC_QUORUM_TIMEOUT);
        return -1;
    
    wait:
        do {
            fiber_yield();
        } while (!txn_limbo_entry_is_complete(entry));
    
    complete:
        fiber_set_cancellable(cancellable);
        if (entry->is_rollback) {
            diag_set(ClientError, ER_SYNC_ROLLBACK);
            return -1;
        }
        return 0;
    }

First, we check for the previous scenario where the relay has already replied
that the replica received and confirmed the data. But we're interested
in the next case where the replica didn't process the new data yet.

So we start waiting for a configurable timeout. This puts us to a wait
cycle where other fibers and threads continue working. In particular while
we're in ``fiber_cond_wait_timeout`` the replica obtains new data, write
it to own WAL and then our master's relay acquire ratification then runs
``tx_status_update`` and ``txn_limbo_ack``, which in turn initiate already
known ``txn_limbo_write_confirm`` and ``txn_limbo_read_confirm`` calls sequence.
The ``IPROTO_CONFIRM`` get written on the master node and propagated to the
replica node then.
