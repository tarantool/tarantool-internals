.. _relay:

Relay
=====

Introduction
------------

Relay serves as a counterpart to replication procedure.

When ``replication``, which specifies replication sources(-s),
is set in the box configuration we connect to the remote peer(-s),
from which we will fetch database updates, to keep all nodes
up to date. These remote peers run the relay service in order
to send all local changes to other nodes.

Relay start up
--------------

Applier fiber is started for every URI in ``replication`` parameter.
It creates the connection to this URI, performs joining procedure if
needed and subscribes for the changes on remote node. With
``applier_join()`` function ``IPROTO_JOIN`` code is sent. It initializes
JOIN procedure on the remote node. The full description about message
exchange, details on working of the ``applier_f`` and the overview of the
JOIN procedure from applier's point of view can be found in
:ref:`replication` internal documents.

In order to see how relay is initialized we should consider how
``IPROTO_JOIN`` is processed on the node, to which it was sent by
the applier:

.. code-block:: c

    /* src/box/iproto.cc */
    static void
    tx_process_replication(struct cmsg *m)
    {
        ...
        switch (msg->header.type) {
        case IPROTO_JOIN:
            box_process_join(io, &msg->header);
            break;

``box_process_join()`` is invoked on receiving of the join code. Firstly,
we initialize joining procedure:

.. code-block:: c

    /* src/box/box.cc */
    void
    box_process_join(struct iostream *io, const struct xrow_header *header)
    {
        ...
        struct join_request req;
        xrow_decode_join_xc(header, &req);

        /* Check that bootstrap has been finished */
        if (!is_box_configured)
            tnt_raise(ClientError, ER_LOADING);
        ...
        /* Add to _cluster space */
        struct replica *replica = replica_by_uuid(&req.instance_uuid);
        if (replica == NULL || replica->id == REPLICA_ID_NIL ||
            strcmp(replica->name, req.instance_name) != 0) {
            box_check_writable_xc();
            struct space *space = space_cache_find_xc(BOX_CLUSTER_ID);
            access_check_space_xc(space, PRIV_W);
        }

        ...
        /* Check permissions, WAL mode and register as a WAL consumer */
        auto replica_guard = box_connect_replica(&req.instance_uuid,
                                                 instance_vclock, &replica);

We make sure that replica has enough permissons, our node is ready for join
(it's WAL is enabled, configuration has finished) and register the consumer,
the purpose of which is to be sure that WAL file is not rotated while there
are some records which are not yet sent to that replica. This way final stage
of join can resume where initial one ends. These steps are now encapsulated in
``box_connect_replica()``: it calls ``access_check_universe_xc(PRIV_R)``,
forbids replication with ``wal_mode = 'none'`` and registers a
``GC_CONSUMER_REPLICA`` consumer via ``gc_consumer_register()``.

Then we create the relay instance for the initial JOIN itself:

.. code-block:: c

    /* src/box/box.cc */
    void
    box_process_join(struct iostream *io, const struct xrow_header *header)
    {
        ...
        struct vclock start_vclock;
        relay_initial_join(io, header->sync, &start_vclock, req.version_id,
                           NULL);
            /* relay_initial_join() code */
            struct relay *relay = relay_new(NULL);
            relay_start(relay, io, sync, relay_send_initial_join_row,
                relay_yield, UINT64_MAX);
            ...
            /* Freeze a read view in engines. */
            struct engine_join_ctx ctx;
            engine_prepare_join_xc(&ctx);
            ...
            struct box_checkpoint box_ckpt;
            box_checkpoint_build_in_memory(&box_ckpt);
            ...
            /* Respond to the JOIN request with the current vclock. */
            send_join_header(&relay->stream, &box_ckpt.journal.vclock);

            /* JOIN_META */
            if (replica_version_id > 0)
                send_join_meta(&relay->stream, &box_ckpt);

            /* Send read view to the replica. */
            engine_join_xc(&ctx, &relay->stream);


The ``relay_initial_join`` sends a stream of engine-specific rows (e.g.
snapshot rows for memtx or dirty cursor data for Vinyl fed from a read-view)
to the remote replica.

For this the function creates new relay structure and gets a read view from
engine, after that it collects the checkpoint state (``struct box_checkpoint``)
which includes the limbo state, storing synchronous transactions in progress
of collecting ACKs from replicas, and the raft state. Both are sent in the
JOIN META stage if the protocol of the replica supports this stage. At the end
we send a read view with all the meta information we gathered and free
``relay`` instance upon completion.

Then we continue joining procedure

.. code-block:: c

    /* src/box/box.cc */
    void
    box_process_join(struct iostream *io, const struct xrow_header *header)
    {
        ...
        /* Register the replica */
        box_register_replica(&req.instance_uuid, req.instance_name);
        ...
        /* Master's vclock */
        struct vclock stop_vclock;
        vclock_copy(&stop_vclock, instance_vclock);

        /* Send it to the peer */
        struct xrow_header row;
        xrow_encode_vclock_ignore0(&row, &stop_vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        /* The WAL range (start_vclock; stop_vclock) with rows */
        relay_final_join(replica, io, header->sync, &start_vclock,
                         &stop_vclock);

        /* End of WAL marker */
        xrow_encode_vclock_ignore0(&row, instance_vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        /* Advance the consumer position */
        gc_consumer_advance(replica->gc, &stop_vclock);
        ...

We fetch master's node vclock (the ``instance_vclock`` is updated
by WAL engine upon on commit when data is already written to the storage)
and send it out. Then we send the vclock range from ``start_vclock``
to ``stop_vclock`` together with rows bound to the range and end it
sending end of WAL marker.

The ``relay_final_join`` is a bit tricky:

.. code-block:: c

    /* src/box/relay.cc */
    void
    relay_final_join(struct replica *replica, struct iostream *io,
                     uint64_t sync, const struct vclock *start_vclock,
                     const struct vclock *stop_vclock)
    {
        struct relay *relay = replica->relay;
        ...
        relay_start(relay, io, sync, relay_process_row, relay_yield,
                    UINT64_MAX);
        ...
        relay->r = recovery_new(wal_dir(), 0, start_vclock);
        vclock_copy(&relay->stop_vclock, stop_vclock);

        struct cord cord;
        int rc = cord_costart(&cord, "final_join",
                              relay_final_join_f, relay);
        ...
    }

It runs ``relay_final_join_f`` in a separate thread waiting for
its completion. This function runs ``recover_remaining_wals``
which scans the WAL files (they can rotate) for rows associated
with ``{start_vclock; stop_vclock}`` range and send them all to
the remote peer.

After this stage our node is joined and any further communication
will be initiated by replica, once it sends the SUBSCRIBE command
(see ``applier_f()`` at :ref:`replication`). Once received we
prepare our node to send local updates to the peer.

.. code-block:: c

    /* src/box/iproto.cc */
    static void
    tx_process_replication(struct cmsg *m)
    {
        ...
        switch (msg->header.type) {
        ...
        case IPROTO_SUBSCRIBE:
            box_process_subscribe(io, &msg->header);
            break;
        ...

The ``box_process_subscribe()`` never returns but rather watches
for local changes and sends them up. As we remember the same way
the ``applier_subscribe()`` behaves.

The handler is pretty self-explaining:

.. code-block:: c

    /* src/box/box.cc */
    void
    box_process_subscribe(struct iostream *io, const struct xrow_header *header)
    {
        ...
        /* Get vclock of the remote peer */
        struct subscribe_request req;
        xrow_decode_subscribe_xc(header, &req);
        ...
        /* Remember current WAL clock */
        struct subscribe_response rsp;
        memset(&rsp, 0, sizeof(rsp));
        vclock_copy(&rsp.vclock, instance_vclock);
        rsp.replicaset_uuid = REPLICASET_UUID;
        strlcpy(rsp.replicaset_name, REPLICASET_NAME, NODE_NAME_SIZE_MAX);

        /* Send it to the peer */
        struct xrow_header row;
        xrow_encode_subscribe_response(&row, &rsp);

        /* Send replica id to the peer */
        struct replica *self = replica_by_uuid(&INSTANCE_UUID);
        row.replica_id = self->id;
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        if (req.version_id >= version_id(2, 6, 0) && !req.is_anon) {
            /* Send raft state */
            struct raft_request raft_req;
            box_raft_checkpoint_remote(&raft_req);
            xrow_encode_raft(&row, &fiber()->gc, &raft_req);
            relay_filter_raft(&row, req.version_id);
            coio_write_xrow(io, &row);
            sent_raft_term = raft_req.term;
        }

        /* Set 0 component to ours 0 component value */
        box_localize_vclock(&req.vclock, &start_vclock);

        /* Initiate subscription procedure */
        relay_subscribe(replica, io, header->sync, &start_vclock,
                        req.version_id, req.id_filter, sent_raft_term);
    }

The subscription routine runs until explicitly cancelled:

.. code-block:: c

    /* src/box/relay.cc */
    void
    relay_subscribe(struct replica *replica, struct iostream *io, uint64_t sync,
                    const struct vclock *start_vclock,
                    uint32_t replica_version_id, uint32_t replica_id_filter,
                    uint64_t sent_raft_term)
    {
        struct relay *relay = replica->relay;
        ...
        relay_start(relay, io, sync, relay_process_row,
                    relay_subscribe_on_wal_yield_f, sent_raft_term);
        ...
        vclock_copy(&relay->local_vclock_at_subscribe, instance_vclock);
        relay->r = recovery_new(wal_dir(), RECOVERY_SUPPRESS_LOGGING,
                                start_vclock);
        vclock_copy_ignore0(&relay->tx.vclock, start_vclock);
        ...
        struct cord cord;
        int rc = cord_costart(&cord, "subscribe",
                              relay_subscribe_f, relay);
        ...
    }

The ``relay->r = recovery_new`` provides us access to the WAL files while
``relay_subscribe_f`` runs inside a separate thread.

.. code-block:: c

    /* src/box/relay.cc */
    static int
    relay_subscribe_f(va_list ap)
    {
        struct relay *relay = va_arg(ap, struct relay *);

        relay_cord_init(relay);

        cbus_endpoint_create(&relay->tx_endpoint,
                     tt_sprintf("relay_tx_%p", relay),
                     fiber_schedule_cb, fiber());
        cbus_pair("tx", relay->tx_endpoint.name, &relay->tx_pipe,
              &relay->relay_pipe, relay_thread_on_start, relay,
              cbus_process);

        cbus_endpoint_create(&relay->wal_endpoint,
                     tt_sprintf("relay_wal_%p", relay),
                     fiber_schedule_cb, fiber());
        ...
        /* Setup WAL watcher for sending new rows to the replica. */
        wal_set_watcher(&relay->wal_watcher, relay->wal_endpoint.name,
                        relay_process_wal_event, cbus_process);

        /* Start fiber for receiving replica acks. */
        char name[FIBER_NAME_MAX];
        snprintf(name, sizeof(name), "%s:%s", fiber()->name, "reader");
        struct fiber *reader = fiber_new(name, relay_reader_f);
        fiber_set_joinable(reader, true);
        fiber_start(reader, relay, fiber());

        relay_send_heartbeat(relay);
        ...
    }

Firstly, we create ``relay->tx_endpoint`` endpoint,and pair it
with ``tx`` endpoint. Once paired we will have ``relay->tx_pipe``
which serves as a uni-directional queue from ``relay`` thread to
``tx`` and ``relay->relay_pipe`` - from ``tx`` to ``relay``.
``relay_thread_on_start()`` sets ``relay->tx.is_paired``
saying to ``tx`` that relay is ready to accept raft pushes
(see ``relay_push_raft()`` below).

Then we setup a watcher on WAL changes. On every new commit
the ``relay_process_wal_event`` will be called which calls
the ``recover_remaining_wals`` helper to advance xlog cursor
in the WAL file and send new rows to the remote replica.
``wal_set_watchar`` pairs relay's ``wal_endpoint`` with ``wal``,
which works inside the WAL thread (see ``wal_writer_f`` in
:ref:`wal`).

The reader of new Acks coming from remote node is implemented
via ``relay_reader_f`` fiber. The one of the key moment is
that all replicas are sending heartbeat messages each other
pointing that they are alive.

In summary in the field of cbus we have:

  - endpoint ``"tx_endpoint"`` which listens for events inside relay thread
    from ``tx``;
  - cpipe ``tx_pipe`` to notify ``tx`` thread from inside of relay thread;
  - cpipe ``relay_pipe`` to notify relay thread from inside of ``tx`` thread.
  - endpoint ``"wal_endpoint"`` for events from the wal thread;
  - cpipes from and to the wal thread are located inside the wal watcher;

Relay lifecycle
---------------

``relay_subscribe_f`` sends current recovery vector clock as
a marker of the "current" state of the master. When replica
fetches rows up to this position, it knows it is synced with
the master. Heartbeats are also sent in this fiber.

.. code-block:: c

    /* src/box/relay.cc */
    static int
    relay_subscribe_f(va_list ap)
    {
        ...
        while (!fiber_is_cancelled()) {
            /*
             * Wait for incoming data from remote
             * peer (it is Ack/Heartbeat message)
             */
            double timeout = replication_timeout;
            ...
            fiber_cond_wait_deadline(&relay->reader_cond,
                         relay->last_row_time + timeout);

            ...
            cbus_process(&relay->wal_endpoint);
            relay_subscribe_update(relay);
            ...
        }
        ...
    }

    static void
    relay_subscribe_update(struct relay *relay)
    {
        struct errinj *inj = errinj(ERRINJ_RELAY_FROM_TX_DELAY, ERRINJ_BOOL);
        if (inj == NULL || !inj->bparam)
            cbus_process(&relay->tx_endpoint);
        relay_send_heartbeat_on_timeout(relay);
        relay_check_status_needs_update(relay);
    }

    static void
    relay_check_status_needs_update(struct relay *relay)
    {
        struct applier_heartbeat *last_recv_ack = &relay->last_recv_ack;
        struct relay_status_msg *status_msg = &relay->status_msg;
        /*
         * Check that the vclock has been updated and the previous
         * status message is delivered
         */
        if (status_msg->msg.route != NULL)
            return;

        struct vclock *send_vclock;
        if (relay->version_id < version_id(1, 7, 4))
            send_vclock = &relay->r->vclock;
        else
            send_vclock = &last_recv_ack->vclock;

        /* Collect xlog files received by the replica. */
        relay_schedule_pending_gc(relay, send_vclock);

        /* Nothing to do */
        double tx_idle = ev_monotonic_now(loop()) - relay->tx_seen_time;
        if (vclock_sum(&status_msg->vclock) ==
            vclock_sum(send_vclock) && tx_idle <= replication_timeout &&
            status_msg->vclock_sync == last_recv_ack->vclock_sync)
            return;
        static const struct cmsg_hop route[] = {
            {tx_status_update, NULL}
        };
        cmsg_init(&status_msg->msg, route);
        vclock_copy_ignore0(&status_msg->vclock, send_vclock);
        status_msg->txn_lag = relay->txn_lag;
        status_msg->relay = relay;
        status_msg->term = last_recv_ack->term;
        status_msg->vclock_sync = last_recv_ack->vclock_sync;
        cpipe_push(&relay->tx_pipe, &status_msg->msg);
    }

Firstly, we wait for heartbeat packet from remote peer (the
``relay_reader_f`` will wake us up via ``relay->reader_cond``).
Then we send our own heartbeat message if ``tx`` thread is
responsive. And finally we send the last received vclock (and the
vclock sync value) from the remote peer. Same time we notify xlog
engine about WAL files we no longer need since they are propagated.

Note that WAL commits runs ``relay_process_wal_event`` by
self, still the event is delivered to main event loop and then
to the relay thread.

Relay Raft
---------------

The only function which is related to Raft and exported to the public relay
API is ``relay_push_raft()``. It's used in order to send raft update request
from the tx thread to relay, after which it is forwarded to the
remote peer, and then returned to the tx.

Let's consider the way it's done. The similar constructions can be found
between "applier thread" and applier fiber in tx thread, iproto and tx
(iproto kharon).

A lot of times cbus serves as means to notify one thread of some news
happening in another thread. Noone limits the pace at which the notifications
appear. For example, ``relay_push_raft`` may be triggered tens of times a
second, if raft terms are bumped fast enough. We don't want to dynamically
allocate tens of cbus messages in such cases, and we are fine with losing
older messages as long as we deliver newer ones.

.. code-block:: c

    /* src/box/relay.cc */
    struct relay {
        ...
        struct {
            ...
            bool is_paired;
            struct relay_raft_msg raft_msgs[2];
            int raft_ready_msg;
            bool is_raft_push_pending;
            bool is_raft_push_sent;
            ...
        } tx;
    };


We usually pre-allocate 2 messages (like we did here in relay structure:
relay->tx.raft_msgs). At any given point in time, at least one of the two
messages resides in sender thread (tx), it receives any updates that arrive
while the other message is somewhere between sender and receiver (tx and
relay).

.. code-block:: c

     /* src/box/relay.cc */
     void
     relay_push_raft(struct relay *relay, const struct raft_request *req)
     {
         /* Choose the idle message */
         struct relay_raft_msg *msg =
             &relay->tx.raft_msgs[relay->tx.raft_ready_msg];
         /* Update the request, overwrite if needed */
         msg->req = *req;
         ...
         /* Send to the remote peer */
         msg->route[0].f = relay_raft_msg_push;
         msg->route[0].pipe = &relay->tx_pipe;

         /* Retry if needed */
         msg->route[1].f = tx_raft_msg_return;
         msg->route[1].pipe = NULL;
         cmsg_init(&msg->base, msg->route);
         msg->relay = relay;
         relay->tx.is_raft_push_pending = true;
         relay_push_raft_msg(relay);
             /* relay_push_raft_msg() code */
             bool is_raft_enabled = relay->tx.is_paired &&
                 !relay->replica->anon &&
                 relay->version_id >= version_id(2, 6, 0);
             if (!is_raft_enabled || relay->tx.is_raft_push_sent)
                return;
             struct relay_raft_msg *msg =
                 &relay->tx.raft_msgs[relay->tx.raft_ready_msg];
             cpipe_push(&relay->relay_pipe, &msg->base);
             relay->tx.raft_ready_msg = (relay->tx.raft_ready_msg + 1) % 2;
             relay->tx.is_raft_push_sent = true;
             relay->tx.is_raft_push_pending = false;
     }

Firstly, we choose the message, which is idling in tx thread and ready to
save Raft requests. After that we update the request, not paying attention
to the data saved in it. As soon as the route of the message (see `cbus`)
is set, it's pushed to cpipe directed to the relay thread. The message can be
pushed only if ``is_raft_enabled`` is true. That is a locally computed
condition (there is no such field anymore): the relay must be paired
(``relay->tx.is_paired``), the replica must not be anonymous and its version
must be at least 2.6.0. ``is_raft_push_pending`` means the message was saved
but not sent yet, while `is_raft_push_sent` shows whether any of the messages
is en route between threads, so it must equal to false, as otherwise there
will be no idle message to store incoming updates in tx.

As soon as msg is delivered to relay thread ``relay_raft_msg_push()``,
which sends message to the remote peer via network (1st route), is executed:

.. code-block:: c

    /* src/box/relay.cc */
    static void
    relay_raft_msg_push(struct cmsg *base)
    {
        struct relay_raft_msg *msg = (struct relay_raft_msg *)base;
        struct relay *relay = msg->relay;
        struct xrow_header row;
        RegionGuard region_guard(&fiber()->gc);
        xrow_encode_raft(&row, &fiber()->gc, &msg->req);
        relay_send_raft(relay, &row);
        if (relay_flush(relay) < 0) {
            relay_set_error(relay, diag_last_error(diag_get()));
            fiber_cancel(fiber());
        }
        relay->sent_raft_term = msg->req.term;
    }

This function sends the message to the remote peer. After that the message is
returned to the tx thread and it is checked if the other message has new
updates: `is_raft_push_sent` flag blocked sending of the new messages, now
it's released and a new message, saved in the other index of the `raft_msgs`
(not the same as was just returned back) is already ready to be pushed to the
relay thread:

.. code-block:: c

    /* src/box/relay.cc */
    static void
    tx_raft_msg_return(struct cmsg *base)
    {
        struct relay_raft_msg *msg = (struct relay_raft_msg *)base;
        /* no message is en route */
        msg->relay->tx.is_raft_push_sent = false;
        /* if the other message was already saved into raft_msgs[] */
        if (msg->relay->tx.is_raft_push_pending)
            relay_push_raft_msg(msg->relay);
    }
