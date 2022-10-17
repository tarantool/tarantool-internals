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

    /* box/iproto.cc */
    static void
    tx_process_replication(struct cmsg *m)
    {
        ...
        switch (msg->header.type) {
        case IPROTO_JOIN:
            box_process_join(&io, &msg->header);
            break;

``box_process_join()`` is invoked on receiving of the join code. Firstly,
we initialize joining procedure:

.. code-block:: c

    /* box/box.cc */
    void
    box_process_join(struct ev_io io, struct xrow_header *header)
    {
        ...
        xrow_decode_join_xc(header, &instance_uuid, &replica_version_id);

        /* Check that bootstrap has been finished */
        if (!is_box_configured)
            tnt_raise(ClientError, ER_LOADING);
        ...
	    /* Check permissions */
	    access_check_universe_xc(PRIV_R);
        ...
        /* Add to _cluster space */
        struct replica *replica = replica_by_uuid(&instance_uuid);
        if (replica == NULL || replica->id == REPLICA_ID_NIL) {
            box_check_writable_xc();
            struct space *space = space_cache_find_xc(BOX_CLUSTER_ID);
            access_check_space_xc(space, PRIV_W);
        }

        /* Forbid replication with disabled WAL */
        if (wal_mode() == WAL_NONE) {
            tnt_raise(ClientError, ER_UNSUPPORTED, ...)
        }

        /* Register the replica as a WAL consumer so that */
        struct gc_consumer *gc = gc_consumer_register(&replicaset.vclock,
                    "replica %s", tt_uuid_str(&instance_uuid));
        auto gc_guard = make_scoped_guard([&] { gc_consumer_unregister(gc); });

We make sure that replica has enough permissons, our node is ready for join
(it's WAL is enabled, configuration has finished) and register the consumer,
the purpose of which is to be sure that WAL file is not rotated while there
are some records which are not yet sent to that replica. This way final stage
of join can resume where initial one ends.

Then we create the relay instance for the initial JOIN itself:

.. code-block:: c

    /* box/box.cc */
    void
    box_process_join(struct ev_io *io, struct xrow_header *header)
    {
        ...
        struct vclock start_vclock;
        relay_initial_join(io->fd, header->sync, &start_vclock);
            /* relay_initial_join() code */
            struct relay *relay = relay_new(NULL);
            relay_start(relay, io, sync, relay_send_initial_join_row,
                relay_yield, UINT64_MAX);
            ...
            /* Freeze a read view in engines. */
            struct engine_join_ctx ctx;
            engine_prepare_join_xc(&ctx);
            ...
            wal_sync(vclock)
            ...
            txn_limbo_wait_confirm(&txn_limbo)
            ...
            txn_limbo_checkpoint(&txn_limbo, &req);
            box_raft_checkpoint_local(&raft_req);
            ...
            /* Respond to the JOIN request with the current vclock. */
            xrow_encode_vclock_xc(&row, vclock);
            coio_write_xrow(relay->io, &row);

            /* JOIN_META */
            if (replica_version_id > 0) {
                xrow_encode_type(&row, IPROTO_JOIN_META);
                xstream_write(&relay->stream, &row);

                xrow_encode_raft(&row, &fiber()->gc, &raft_req);
                xstream_write(&relay->stream, &row);

                char body[XROW_SYNCHRO_BODY_LEN_MAX];
                xrow_encode_synchro(&row, body, &req);
                row.replica_id = req.replica_id;
                xstream_write(&relay->stream, &row);

                xrow_encode_type(&row, IPROTO_JOIN_SNAPSHOT);
                xstream_write(&relay->stream, &row);
            }

            /* Send read view to the replica. */
            engine_join_xc(&ctx, &relay->stream);


The ``relay_initial_join`` sends a stream of engine-specific rows (e.g.
snapshot rows for memtx or dirty cursor data for Vinyl fed from a read-view)
to the remote replica.

For this the function creates new relay structure and prepares data to be
sent. Firstly, we create a new relay structure and get a read view from
engine, after that we save the state of the limbo, which stores synchronous
transactions in progress of collecting ACKs from replicas, state of the raft
protocol in messages, which will be sent lately in JOIN META stage if the
protocol of the replica supports this stage. At the end we send a read view
with all the meta information we gathered and free ``relay`` instance upon
completion.

Then we continue joining procedure

.. code-block:: c

    /* box/box.cc */
    void
    box_process_join(struct ev_io *io, struct xrow_header *header)
    {
        ...
        /* Check for replicaid or register new one */
        box_on_join(&instance_uuid);
        ...
        /* Master's vclock */
        struct vclock stop_vclock;
        vclock_copy(&stop_vclock, &replicaset.vclock);

        /* Send it to the peer */
        struct xrow_header row;
        xrow_encode_vclock_xc(&row, &stop_vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        /* The WAL range (start_vclock; stop_vclock) with rows */
        relay_final_join(io->fd, header->sync, &start_vclock, &stop_vclock);

        /* End of WAL marker */
        xrow_encode_vclock_xc(&row, &replicaset.vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        /* Advance the consumer position */
        gc_consumer_advance(gc, &stop_vclock);
        ...

We fetch master's node vclock (the ``replicaset.vclock`` is updated
by WAL engine upon on commit when data is already written to the storage)
and send it out. Then we send the vclock range from ``start_vclock``
to ``stop_vclock`` together with rows bound to the range and end it
sending end of WAL marker.

The ``relay_final_join`` is a bit tricky:

.. code-block:: c

    /* box/relay.cc */
    void
    relay_final_join(int fd, uint64_t sync, struct vclock *start_vclock,
                     struct vclock *stop_vclock)
    {
        struct relay *relay = relay_new(NULL);
        ...
        relay_start(relay, fd, sync, relay_send_row);
            ...
            relay->state = RELAY_FOLLOW;
        ...
        relay->r = recovery_new(cfg_gets("wal_dir"), false,
                                start_vclock);
        vclock_copy(&relay->stop_vclock, stop_vclock);

        int rc = cord_costart(&relay->cord, "final_join",
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

    /* box/iproto.cc */
    static void
    tx_process_replication(struct cmsg *m)
    {
        ...
        switch (msg->header.type) {
        ...
        case IPROTO_SUBSCRIBE:
            box_process_subscribe(&io, &msg->header);
            break;
        ...

The ``box_process_subscribe()`` never returns but rather watches
for local changes and sends them up. As we remember the same way
the ``applier_subscribe()`` behaves.

The handler is pretty self-explaining:

.. code-block:: c

    /* box/box.cc */
    void
    box_process_subscribe(struct ev_io *io, struct xrow_header *header)
    {
        ...
        /* Get vclock of the remote peer */
        xrow_decode_subscribe_xc(header, NULL, &replica_uuid, &replica_clock,
                                 &replica_version_id, &anon, &id_filter);
        ...
        /* Remember current WAL clock */
        vclock_create(&vclock);
        vclock_copy(&vclock, &replicaset.vclock);

        /* Send it to the peer */
        struct xrow_header row;
        xrow_encode_subscribe_response_xc(&row, &REPLICASET_UUID, &vclock);

        /* Send replica id to the peer */
        struct replica *self = replica_by_uuid(&INSTANCE_UUID);
        row.replica_id = self->id;
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        if (replica_version_id >= version_id(2, 6, 0) && !anon) {
            /* Send raft state */
            struct raft_request req;
            box_raft_checkpoint_remote(&req);
            xrow_encode_raft(&row, &fiber()->gc, &req);
            coio_write_xrow(io, &row);
            sent_raft_term = req.term;
        }

        /* Set 0 component to ours 0 component value */
        vclock_reset(&replica_clock, 0, vclock_get(&replicaset.vclock, 0));

        /* Initiate subscription procedure */
        relay_subscribe(replica, io->fd, header->sync, &replica_clock,
                        replica_version_id, id_filter);
    }

The subscription routine runs until explicitly cancelled:

.. code-block:: c

    /* box/relay.cc */
    void
    relay_subscribe(struct replica *replica, int fd, uint64_t sync,
                    struct vclock *replica_clock, uint32_t replica_version_id,
                    uint32_t replica_id_filter)
    {
        struct relay *relay = replica->relay;
        ...
        relay_start(relay, fd, sync, relay_send_row);
        ...
        vclock_copy(&relay->local_vclock_at_subscribe, &replicaset.vclock);
        relay->r = recovery_new(cfg_gets("wal_dir"), false, replica_clock);
        vclock_copy(&relay->tx.vclock, replica_clock);
        ...
        int rc = cord_costart(&relay->cord, "subscribe",
                              relay_subscribe_f, relay);
        ...
    }

The ``relay->r = recovery_new`` provides us access to the WAL files while
``relay_subscribe_f`` runs inside a separate thread.

.. code-block:: c

    /* box/relay.cc */
    static int
    relay_subscribe_f(va_list ap)
    {
        struct relay *relay = va_arg(ap, struct relay *);

        coio_enable();
        relay_set_cord_name(relay->io->fd);

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
        wal_set_watcher(&relay->wal_watcher, relay->endpoint.name,
                        relay_process_wal_event, cbus_process);

        /* Start fiber for receiving replica acks. */
        char name[FIBER_NAME_MAX];
        snprintf(name, sizeof(name), "%s:%s", fiber()->name, "reader");
        struct fiber *reader = fiber_new_xc(name, relay_reader_f);
        fiber_set_joinable(reader, true);
        fiber_start(reader, relay, fiber());

        relay_send_heartbeat(relay);
        ...
    }

Firstly, we create ``relay->tx_endpoint`` endpoint,and pair it
with ``tx`` endpoint. Once paired we will have ``relay->tx_pipe``
which serves as a uni-directional queue from ``relay`` thread to
``tx`` and ``relay->relay_pipe`` - from ``tx`` to ``relay``.
``relay_thread_on_start()`` sets ``relay->tx.is_raft_enabled``
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

    /* box/relay.cc */
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
            cbus_process(&relay->tx_endpoint);
            cbus_process(&relay->wal_endpoint);

            /* Send the heartbeat if needed */
            relay_send_heartbeat_on_timeout(relay);

            /*
             * Check that the vclock has been updated and the previous
             * status message is delivered
             */
            if (relay->status_msg.msg.route != NULL)
                continue;

            struct vclock *send_vclock;
            if (relay->version_id < version_id(1, 7, 4))
                send_vclock = &relay->r->vclock;
            else
                send_vclock = &relay->recv_vclock;

            /* Collect xlog files received by the replica. */
            relay_schedule_pending_gc(relay, send_vclock);

            /* Nothing to do */
            double tx_idle = ev_monotonic_now(loop()) - relay->tx_seen_time;
            if (vclock_sum(&relay->status_msg.vclock) ==
                vclock_sum(send_vclock) && tx_idle <= timeout &&
                relay->status_msg.vclock_sync == relay->recv_vclock_sync)
                continue;
            static const struct cmsg_hop route[] = {
                {tx_status_update, NULL}
            };
            cmsg_init(&relay->status_msg.msg, route);
            vclock_copy(&relay->status_msg.vclock, send_vclock);
            relay->status_msg.txn_lag = relay->txn_lag;
            relay->status_msg.relay = relay;
            relay->status_msg.vclock_sync = relay->recv_vclock_sync;
            cpipe_push(&relay->tx_pipe, &relay->status_msg.msg);
        }
        ...
    }

Firstly, we wait for heartbeat packet from remote peer (the
``relay_reader_f`` will wake us up via ``relay->reader_cond``).
Then we send our own heartbeat message if ``tx`` thread is
responsive. And finally we send the last received vclock from the
remote peer. Same time we notify xlog engine about WAL files we no
longer need since they are propagated.

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

    /* box/relay.cc */
    struct relay {
        ...
        struct {
            ...
            struct relay_raft_msg raft_msgs[2];
            int raft_ready_msg;
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

     /* box/relay.cc */
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
             if (!relay->tx.is_raft_enabled || relay->tx.is_raft_push_sent)
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
pushed only if ``is_raft_enabled`` flag is set, which means ``tx_pipe`` and
``relay_pipe`` have already been created. `is_raft_push_sent` shows whether
any of the messages is en route between threads, so it must equal to false,
as otherwise there will be no idle message to store incoming updates in tx.

As soon as msg is delivered to relay thread ``relay_raft_msg_push()``,
which sends message to the remote peer via network (1st route), is executed:

.. code-block:: c

    /* box/relay.cc */
    static void
    relay_raft_msg_push(struct cmsg *base)
    {
        struct relay_raft_msg *msg = (struct relay_raft_msg *)base;
        struct xrow_header row;
        xrow_encode_raft(&row, &fiber()->gc, &msg->req);
        try {
            /* Send via network */
            relay_send(msg->relay, &row);
            msg->relay->sent_raft_term = msg->req.term;
        } catch (Exception *e) {
            relay_set_error(msg->relay, e);
            fiber_cancel(fiber());
        }
    }

This function sends the message to the remote peer. After that the message is
returned to the tx thread and it is checked if the other message has new
updates: `is_raft_push_sent` flag blocked sending of the new messages, now
it's released and a new message, saved in the other index of the `raft_msgs`
(not the same as was just returned back) is already ready to be pushed to the
relay thread:

.. code-block:: c

    /* box/relay.cc */
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
