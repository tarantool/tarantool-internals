Relay
=====

Introduction
------------

Relay serves as a counterpart to replication procedure.

When ``replication``, which specifies replication sources(-s),
is set in the box configuration we connect to the remote peer,
from which we will fetch database updates, to keep all nodes
up to date.

Same time the local changes made on the node should be sent
out to the remote peers. For this sake we run the relay service.

Relay start up and JOIN protocol
--------------

Here's the general overview of the Tarantool 1.7 JOIN protocol:

::
    Replica => Master

    => JOIN { INSTANCE_UUID: replica_uuid }
    <= OK { VCLOCK: start_vclock }
       Replica has enough permissions and master is ready for JOIN.
        - start_vclock - master's vclock at the time of join.

    <= INSERT
       ...
       Initial data: a stream of engine-specific rows, e.g. snapshot
       rows for memtx or dirty cursor data for Vinyl fed from a
       read-view. Engine can use REPLICA_ID, LSN and other fields
       for internal purposes.
       ...
    <= INSERT
    <= OK { VCLOCK: stop_vclock } - end of initial JOIN stage.
        - `stop_vclock` - master's vclock when it's done
        done sending rows from the snapshot (i.e. vclock
        for the end of final join).

    <= INSERT/REPLACE/UPDATE/UPSERT/DELETE { REPLICA_ID, LSN }
       ...
       Final data: a stream of WAL rows from `start_vclock` to
       `stop_vclock`, inclusive. REPLICA_ID and LSN fields are
       original values from WAL and master-master replication.
       ...
    <= INSERT/REPLACE/UPDATE/UPSERT/DELETE { REPLICA_ID, LSN }
    <= OK { VCLOCK: current_vclock } - end of final JOIN stage.
         - `current_vclock` - master's vclock after final stage.

    All packets must have the same SYNC value as initial JOIN request.
    Master can send ERROR at any time. Replica doesn't confirm rows
    by OKs. Either initial or final stream includes:
     - Cluster UUID in _schema space
     - Registration of master in _cluster space
     - Registration of the new replica in _cluster space

When replica connects to the master it sends ``IPROTO_JOIN`` code
via network message (the full process about message exchange is
described in replication section):

.. code-block:: c

    static int
    applier_f(va_list ap)
    {
        ...
        /* Re-connect loop */
        while (!fiber_is_cancelled()) {
            applier_connect(applier);
            if (tt_uuid_is_nil(&REPLICASET_UUID)) {
                was_anon = replication_anon;
                if (replication_anon)
                    applier_fetch_snapshot(applier);
                else
                    applier_join(applier);
            }
            if (instance_id == REPLICA_ID_NIL &&
                !replication_anon) {
                applier_register(applier, was_anon);
            }
            applier_subscribe(applier);
            unreachable();
            return 0;
        }
        ...
    }

Applier fiber is started for every URI in ``replication`` parameter.
It creates the connection to the master, performs joining procedure
if needed and subscribes for the changes on remote node. ``subscribe()``
has an infinite loop which is stoppable only with fiber_cancel().

Let's now move to the master node and see, how ``IPROTO_JOIN`` is
processed there:

.. code-block:: c

    static void
    tx_process_replication(struct cmsg *m)
    {
        ...
        switch (msg->header.type) {
        case IPROTO_JOIN:
            box_process_join(&io, &msg->header);
            break;

``box_process_join()`` is invoked on receiving of the join code.
Firstly, we initialize joining procedure:

.. code-block:: c

    void
    box_process_join(struct ev_io ``io, struct xrow_header *header)
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

        /*
         * Register the replica as a WAL consumer so that
         * it can resume FINAL JOIN where INITIAL JOIN ends.
         */
        struct gc_consumer *gc = gc_consumer_register(&replicaset.vclock,
                    "replica %s", tt_uuid_str(&instance_uuid));
        auto gc_guard = make_scoped_guard([&] { gc_consumer_unregister(gc); });

We make sure that replica has enough permissons, our node is ready for join
(it's WAL is enabled, configuration has finished) and register the consumer,
the purpose of which is to be sure that WAL file is not rotated while there
are some records which are not yet propagated to the whole cluster. This way
final stage of join can resume where initial one ends.

Then we create the relay instance for the initial JOIN itself:

.. code-block:: c

    void
    box_process_join(struct ev_io *io, struct xrow_header *header)
    {
        ...
        struct vclock start_vclock;
        relay_initial_join(io->fd, header->sync, &start_vclock);
            // relay_initial_join() code
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


The ``relay_initial_join`` sends a stream of engine-specific rows to the
remote replica.

For this the function creates new relay structure and prepares data to be sent.
Firstly, we create a new relay structure and get a read view from engine, after
that we save the state of the limbo, which stores synchronous transactions in
progress of collecting ACKs from replicas, state of the raft protocol in messages,
which will be sent lately in JOIN META stage if the protocol of the replica
supports this stage. At the end we send a read view with all the meta information
we gathered and free ``relay`` instance upon completion.

Then we continue joining procedure

.. code-block:: c

    void
    box_process_join(struct ev_io *io, struct xrow_header *header)
    {
        ...
        // Check for replicaid or register new one
        box_on_join(&instance_uuid);
        ...
        // Master's vclock
        struct vclock stop_vclock;
        vclock_copy(&stop_vclock, &replicaset.vclock);

        // Send it to the peer
        struct xrow_header row;
        xrow_encode_vclock_xc(&row, &stop_vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        // The WAL range (start_vclock; stop_vclock) with rows
        relay_final_join(io->fd, header->sync, &start_vclock, &stop_vclock);

        // End of WAL marker
        xrow_encode_vclock_xc(&row, &replicaset.vclock);
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        // Advance the consumer position
        gc_consumer_advance(gc, &stop_vclock);
        ...

We fetch master's node vclock (the ``replicaset.vclock`` is updated
by WAL engine upon on commit when data is already written to the storage)
and send it out. Then we send the vclock range from ``start_vclock``
to ``stop_vclock`` together with rows bound to the range and end it
sending end of WAL marker.

The ``relay_final_join`` is a bit tricky:

.. code-block:: c

    void
    relay_final_join(int fd, uint64_t sync, struct vclock *start_vclock,
                     struct vclock *stop_vclock)
    {
        struct relay *relay = relay_new(NULL);
        ...
        relay_start(relay, fd, sync, relay_send_row);
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

After this stage our node is joined and we need to wait for
SUBSCRIBE request from remote peer (see ``applier_f()`` at the
beginning of the document). Once received we prepare our node to
send local updates to the peer.

.. code-block:: c

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

    void
    box_process_subscribe(struct ev_io *io, struct xrow_header *header)
    {
        ...
        // Get vclock of the remote peer
        xrow_decode_subscribe_xc(header, NULL, &replica_uuid, &replica_clock,
                                 &replica_version_id, &anon, &id_filter);
        ...
        // Remember current WAL clock
        vclock_create(&vclock);
        vclock_copy(&vclock, &replicaset.vclock);

        // Send it to the peer
        struct xrow_header row;
        xrow_encode_subscribe_response_xc(&row, &REPLICASET_UUID, &vclock);

        // Send replica id to the peer
        struct replica *self = replica_by_uuid(&INSTANCE_UUID);
        row.replica_id = self->id;
        row.sync = header->sync;
        coio_write_xrow(io, &row);

        if (replica_version_id >= version_id(2, 6, 0) && !anon) {
            // Send raft state
            struct raft_request req;
            box_raft_checkpoint_remote(&req);
            xrow_encode_raft(&row, &fiber()->gc, &req);
            coio_write_xrow(io, &row);
            sent_raft_term = req.term;
        }

        // Set 0 component to ours 0 component value
        vclock_reset(&replica_clock, 0, vclock_get(&replicaset.vclock, 0));

        // Initiate subscription procedure
        relay_subscribe(replica, io->fd, header->sync, &replica_clock,
                        replica_version_id, id_filter);
    }

The subscription routine runs until explicitly cancelled:

.. code-block:: c

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

    static int
    relay_subscribe_f(va_list ap)
    {
        struct relay *relay = va_arg(ap, struct relay *);

        coio_enable();
        relay_set_cord_name(relay->io.fd);

        cbus_endpoint_create(&relay->tx_endpoint,
                             tt_sprintf("relay_tx_%p", relay),
                             fiber_schedule_cb, fiber());
        cbus_pair("tx", relay->tx_endpoint.name, &relay->tx_pipe,
              &relay->relay_pipe, NULL, NULL, cbus_process);

        cbus_endpoint_create(&relay->wal_endpoint,
                     tt_sprintf("relay_wal_%p", relay),
                     fiber_schedule_cb, fiber());

        struct relay_is_raft_enabled_msg raft_enabler;
        if (!relay->replica->anon && relay->version_id >= version_id(2, 6, 0))
            relay_send_is_raft_enabled(relay, &raft_enabler, true);
        else
            relay->sent_raft_term = UINT64_MAX;
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

        /*
         * If the replica happens to be up to date on subscribe,
         * don't wait for timeout to happen - send a heartbeat
         * message right away to update the replication lag as
         * soon as possible.
         */
        relay_send_heartbeat(relay);
        ...
    }

Firstly, we create ``relay->tx_endpoint`` endpoint and pair it
with ``tx`` endpoint (the ``tx`` endpoint comes from net thread
spinning inside ``net_cord_f``). Once paired we will have
``relay->tx_pipe`` which responsible to notify ``tx`` thread
to send out the data we provide, and ``relay->relay_pipe``
which notifies relay thread from ``tx`` thread side.

After that we set relay Raft enabled flag from a relay thread
to be accessed by the ``tx`` thread.

Then we setup a watcher on WAL changes. On every new commit
the ``relay_process_wal_event`` will be called which calls
the ``recover_remaining_wals`` helper to advance xlog cursor
in the WAL file and send new rows to the remote replica.

The reader of new Acks coming from remote node is implemented
via ``relay_reader_f`` fiber. The one of the key moment is
that all replicas are sending heartbeat messages each other
pointing that they are alive.

Relay lifecycle
---------------

``relay_subscribe_f`` sends current recovery vector clock as
a marker of the "current" state of the master. When replica
fetches rows up to this position, it enters read-write mode.
Heartbeats are also sent in this fiber.

.. code-block:: c

    static int
    relay_subscribe_f(va_list ap)
    {
        ...
        while (!fiber_is_cancelled()) {
            // Wait for incoming data from remote
            // peer (it is Ack/Heartbeat message)
            double timeout = replication_timeout;
            fiber_cond_wait_deadline(&relay->reader_cond,
                                     relay->last_row_time + timeout);
            ...
            // Handle cbus messages from WAL and TX and send the heartbeat
			cbus_process(&relay->tx_endpoint);
            cbus_process(&relay->wal_endpoint);
            relay_send_heartbeat_on_timeout(relay);

            // Make sure that vclock has been updated
            // and the previous status is delivered.
            if (relay->status_msg.msg.route != NULL)
                continue;

            struct vclock *send_vclock;
            if (relay->version_id < version_id(1, 7, 4))
                send_vclock = &r->vclock;
            else
                send_vclock = &relay->recv_vclock;

            // Nothing to do
            if (vclock_sum(&relay->status_msg.vclock) ==
                vclock_sum(send_vclock) &&
                ev_monotonic_now(loop()) - relay->tx_seen_time <= timeout)
                    continue;
            static const struct cmsg_hop route[] = {
                {tx_status_update, NULL}
            };

            cmsg_init(&relay->status_msg.msg, route);
            vclock_copy(&relay->status_msg.vclock, send_vclock);
            relay->status_msg.txn_lag = relay->txn_lag;
            relay->status_msg.relay = relay;
            cpipe_push(&relay->tx_pipe, &relay->status_msg.msg);
        }
        ...
    }

As expected we wait for heartbeat packet from remote peer first
(the ``relay_reader_f`` will wake us up via ``relay->reader_cond``).
Then we send our own heartbeat message if needed. And finally
we send the last received vclock from the remote peer. Same
time we notify xlog engine about WAL files we no longer need
since they are propagated.

Note that WAL commits runs ``relay_process_wal_event`` by
self, still the event is delivered to main event loop and then
to the relay thread.
