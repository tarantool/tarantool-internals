Replication
===========

Introduction
------------

The following sections describe replication procedure.

Replication in 1.10 series
--------------------------

Code flow
~~~~~~~~~

Entry point is in ``box_cfg_xc`` routine which is called once box
configuration initiated (via command line or startup script).

.. code-block:: c

    void
    replication_init(void)
    {
        memset(&replicaset, 0, sizeof(replicaset));
        replica_hash_new(&replicaset.hash);
        rlist_create(&replicaset.anon);
        vclock_create(&replicaset.vclock);
        fiber_cond_create(&replicaset.applier.cond);
        replicaset.replica_by_id = calloc(VCLOCK_MAX, ...);
        latch_create(&replicaset.applier.order_latch);
    }

The ``replicaset`` may carry up to ``VCLOCK_MAX=32`` replicas at once.
This limitation is due to saving network bandwidth when nodes communicate
between each other (same time 32 bits are good length for fast lookup, we
treat is as a bitmap).

Once ``replicaset`` is set we consider bootstrap of a new node, ie assume
there is no recovery from checkpoint procedure needed.

.. code-block:: c

    bootstrap(&instance_uuid, &replicaset_uuid,
              &is_bootstrap_leader);
        box_sync_replication(true);

In ``box_sync_replication`` we try to connect to **master** nodes
to receive updates from.

.. code-block:: c

    box_sync_replication
        appliers = cfg_get_replication(&count);
            // max num of appliers is VCLOCK_MAX;
            for (int i = 0; i < count; i++) {
                // get addresses
                *source = cfg_getarr_elem("replication", i);
                // allocate applier entries dynamically
                applier = applier_new(source, ...);
                    fiber_cond_create(&applier->resume_cond);
                    fiber_cond_create(&applier->writer_cond);
        replicaset_connect(appliers, count, connect_quorum);

Here we fetch replicas addresses from config and allocate ``applier`` array.
The ``applier`` will be notified by ``resume_cond`` and ``writer_cond``
conditions.

Then we initiate the connection procedure.

.. code-block:: c

    replicaset_connect(appliers, count, connect_quorum)
        struct applier_on_connect triggers[VCLOCK_MAX];
        struct replicaset_connect_state state;
        state.connected = state.failed = 0;
        fiber_cond_create(&state.wakeup);
        for (int i = 0; i < count; i++) {
            applier = appliers[i];
            trigger = &triggers[i];
            trigger_create(&trigger->base, applier_on_connect_f, ...);
            trigger->state = &state;
            trigger_add(&applier->on_state, &trigger->base);
            applier_start(applier);
                f = fiber_new_xc(name, applier_f);
                fiber_set_joinable(f, true);
                applier->reader = f;
                fiber_start(f, applier);

On every applier fiber allocated we assign a trigger to track the change of
the applier state which is handled by the ``applier_on_connect_f`` helper.

.. code-block:: c

    applier_on_connect_f(struct trigger *trigger, void *event)
        switch (applier->state) {
        case APPLIER_OFF:
        case APPLIER_STOPPED:
            state->failed++;
            break;
        case APPLIER_CONNECTED:
            state->connected++;
            break;
        default:
            // Not interested in any
            // other events just continue
            // executing an applier fiber.
            return;
        }
        // Notify replicaset_connect_state
        // and pause applier, will be kicked
        // to run explicitly.
        fiber_cond_signal(&state->wakeup);
        applier_pause(applier);

This trigger process ``failed`` and ``connected`` statistics which
is needed to fit the replicas quorum.

Note that ``APPLIER_OFF``, ``APPLIER_STOPPED`` and ``APPLIER_CONNECTED``
states notify the ``replicaset_connect`` waiters. Due to cooperative
multitasking model the ``replicaset_connect`` routine need to waits
for notifications from the applier fibers (described below).

Now back to applier fibers. The ``applier_start`` function creates an
``applier`` fiber and immediately runs ``applier_f`` routine.

.. code-block:: c

    applier_f(va_list ap)
        while (!fiber_is_cancelled()) {
            try {
                applier_connect(applier);
                ...
            } catch() {
                ...
            }
        }

In ``applier_connect`` we send a greeting to the remote node
and fetch UUID of the remote machine (of the **master** node).

.. code-block:: c

    applier_connect
        char greetingbuf[IPROTO_GREETING_SIZE];
        coio_connect(coio, uri, &applier->addr, &applier->addr_len);
        coio_readn(coio, greetingbuf, IPROTO_GREETING_SIZE);
        greeting_decode(greetingbuf, &greeting);
        applier->uuid = greeting.uuid;
        applier->version_id = greeting.version_id;
        if (applier->version_id >= version_id(1, 9, 0)) {
            ...
            xrow_decode_ballot_xc(&row, &applier->ballot);
            ...
        }
        // Notify replicaset waiter that we're done.
        // Then pause and wait for a kick.
        applier_set_state(applier, APPLIER_CONNECTED);
        ...

Once we reach ``APPLIER_CONNECTED`` state the fiber get paused
from ``applier_on_connect_f`` trigger. And left in this state
until being explicitly kicked to run.

The ``replicaset_connect`` caller at this moment is spinning in
a cycle waiting for notification from appliers to fit the quorum
of appliers in connected state.

.. code-block:: c

    replicaset_connect
        ...
        while (state.connected < count) {
            ...
            fiber_cond_wait_timeout(&state.wakeup, timeout);
            ...
        }

There are some differences in how many connections are considered enough to
proceed. This is controlled by ``bool connect_quorum`` parameter of
``replicaset_connect``. On a instance bootstrap, i.e. when there are no local
files (.snap, .xlog) to recover from ``connect_quorum`` is ``true``, and this
means that ``replicaset_connect`` tries to connect to ``count`` of remote nodes
for a period of ``replication_connect_timeout``. If the instance fails to
connect to ``count`` of nodes, it continues with at least
``replication_connect_quorum`` of connections, otherwise, an error is thrown:

..  code-block:: c

    replicaset_connect
        ...
        while (state.connected < count)
            ...
        if (state.connected < count)
            ...
            if (connect_quorum && state_connected < quorum) {
                error
                ...

It is important to try connecting to everyone during bootstrap, because
connected appliers are later polled to find the so-called "bootstrap leader",
the node, which will add everyone else to the replicaset. Having a couple of
nodes fail to connect to everyone means they will operate on differing sets of
connections when finding the bootstrap leader, which essentially leads to
conflicts, when two nodes are registering replicas at the same time.

On a normal start though, connecting to everyone is not so critical.
That's why ``connect_quorum`` is ``false`` in this case. This means the node
passes ``replicaset_connect`` faster:

..  code-block:: c

    replicaset_connect
        ...
        while (state.connected < count) {
            ...
            if (state.connected >= quorum && !connect_quorum)
                break;

Once appliers are in ``APPLIER_CONNECTED`` state we clear ``applier_on_connect_f``
trigger and call ``replicaset_update``. Note that not all appliers might
be connected. Those ones which did not manage to are explicitly stopped,
ie fibers are ripped off.

.. code-block:: c

    replicaset_connect
        ...
        for (int i = 0; i < count; i++) {
            trigger_clear(&triggers[i].base);
            if (applier->state != APPLIER_CONNECTED)
                applier_stop(applier);
                    applier_set_state(applier, APPLIER_OFF);
                    applier->reader = NULL;
        }
        try {
            replicaset_update(appliers, count);
        } catch {}

In ``replicaset_update`` we map appliers to replicas and they
are linked into red-black tree ``uniq`` for fast lookup via their UUID.

.. code-block:: c

    replicaset_update(struct applier **appliers, int count)
        ...
        RLIST_HEAD(anon_replicas);
        replica_hash_new(&uniq);
        ...
        for (int i = 0; i < count; i++) {
            applier = appliers[i];
            replica = replica_new();
                replica = malloc(sizeof(struct replica));
                replica->relay = relay_new(replica);
                    relay = calloc(1, sizeof(struct relay));
                    relay->replica = replica;
                    fiber_cond_create(&relay->reader_cond);
                    relay->state = RELAY_OFF;
                replica->id = 0;
                replica->uuid = uuid_nil;
                replica->applier = NULL;
                trigger_create(&replica->on_applier_state,
                                replica_on_applier_state_f, NULL, NULL);
                replica->applier_sync_state = APPLIER_DISCONNECTED;
                latch_create(&replica->order_latch);
            replica_set_applier(replica, applier);
        ...

We allocate new replica and assign an applier to it.

Note that replica state is driven by ``replica_on_applier_state_f``
trigger. We won't be jumping into it right now but the important thing is
that this trigger sends ``fiber_cond_signal(&replicaset.applier.cond)``
to the main replicaset instance.

Now back to the caller, which is the ``applier_sync_state``.
The replica instances are created and we continue walking over appliers:

.. code-block:: c

    replicaset_update(struct applier **appliers, int count)
    ...
        for (int i = 0; i < count; i++) {
            ...
            // continue listing
            replica_set_applier(replica, applier);
            if (applier->state != APPLIER_CONNECTED) {
                // Any not yet connected appliers are
                // chained into anon_replicas list,
                // we will retry to reconnect later.
                rlist_add_entry(&anon_replicas, replica, in_anon);
                continue;
            }
            replica->uuid = applier->uuid;
            replica_hash_insert(&uniq, replica);
        }
        ...

In result we will have two sets, one in ``uniq`` tree which
is intended to keep alive connected replicas and ``anon_replicas``
list which carries not yet connected ones.

Then all alive replicas are marked and connected, statistics updated
and they are moved to global ``replicaset.hash`` tree.

.. code-block:: c

    replicaset_update(struct applier **appliers, int count)
        ...
        replicaset.applier.total = count;
        replicaset.applier.connected = 0;
        replicaset.applier.loading = 0;
        replicaset.applier.synced = 0;
        replica_hash_foreach_safe(&uniq, replica, next) {
            replica_hash_remove(&uniq, replica);
            ...
            replica_hash_insert(&replicaset.hash, replica);
            replica->applier_sync_state = APPLIER_CONNECTED;
            replicaset.applier.connected++;
        }
        ...
        rlist_swap(&replicaset.anon, &anon_replicas);

At the end the anonymous replicas (ones which are not connected)
are moved to global ``replicaset.anon``. So we have
global ``replicaset`` fully consistent and ready for use.

Now we need to jump up to the initial caller ``bootstrap``.

.. code-block:: c

    bootstrap
        ...
        master = replicaset_leader();
            replicaset_round
                replicaset_foreach(replica) {
                    // Walk over unique replicas
                    // from replicaset hash and
                    // choose one with more advanced
                    // vclock or one with lowest UUID
            return leader;

We need to find out how exactly we should start, either
we are the master node or we should start from another
node which is chosen as a cluster leader (i.e. it has
most advanced vclock and low UUID).

Bootstrap first replica
~~~~~~~~~~~~~~~~~~~~~~~

Lets consider bootstrap as a first replica in a cluster. Note
that all previous actions are still intact and appliers in
a replicaset are sitting in connected state and paused.

.. code-block:: c

    bootstrap_master(const struct tt_uuid *replicaset_uuid)
        ...
        replica_id = 1
        box_register_replica(replica_id, &INSTANCE_UUID)
            boxk(IPROTO_INSERT, BOX_CLUSTER_ID, "[%u%s]",
                 (unsigned) id, tt_uuid_str(uuid))
        replicaset_foreach(replica) {
            if (tt_uuid_is_equal(&replica->uuid, &INSTANCE_UUID))
                continue;
            box_register_replica(++replica_id, &replica->uuid);
        }
        box_set_replicaset_uuid(replicaset_uuid)
            boxk(IPROTO_INSERT, BOX_SCHEMA_ID, "[%s%s]", "cluster",
                 tt_uuid_str(&uu))
        wal_enable()
            vclock_copy(&writer->vclock, &replicaset.vclock);
            wal_open(writer)
            journal_set(&writer->base)
        do_checkpoint()
        gc_add_checkpoint(&replicaset.vclock)

We register our node ``replica_id`` in ``_cluster`` internal
service space (as string like ``n9613291f-xxx`` where ``n`` is
a replica number, and 9613291f-xxx is UUID) and then the rest of
replicas are registered as well.

The replicaset is registered in the ``_schema`` internal service
space as a string like ``cluster9613291f-xxx``.

Then the write ahead log (WAL) enabled and the wal writer takes vclock
time from replicaset time and produce initial checkpoint. The initial
vclock for replicaset will be zero since we're not restoring from
snapshot. We become that named bootstrap leader (for this sake we set
``is_bootstrap_leader``).

Once above is done the replicaset enters into "follow" mode. We will
discuss it later because this part is common for bootstrap as a master
and as from a cluster leader.

Bootstrap from a cluster leader
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Bootstrap from remote master node (a cluster leader) is implemented
by ``bootstrap_from_master`` routine which is quite nontrivial.

.. code-block:: c

    bootstrap_from_master(struct replica *master)
        applier = master->applier;
        // Wait the applier to become ready
        applier_resume_to_state(applier, APPLIER_READY);
            struct applier_on_state trigger;
            applier_add_on_state(applier, &trigger, state);
                // Notification from applier handles in applier_on_state_f
                // then in replica_on_applier_state_f
                trigger_create(&trigger->base, applier_on_state_f, ...);
                fiber_cond_create(&trigger->wakeup);
            applier_resume(applier);
            applier_wait_for_state(&trigger, timeout);
            // Once we reach the sate, clear the trigger
            applier_clear_on_state(&trigger);
        applier_resume_to_state(applier, APPLIER_INITIAL_JOIN);
        engine_begin_initial_recovery_xc(NULL);
        applier_resume_to_state(applier, APPLIER_FINAL_JOIN);

One of the key moment here is ``applier_resume_to_state`` helper calls.
As you remember the appliers are bound to replica instance and they all
were in ``APPLIER_CONNECTED`` state when we entered this routine, iow
they are paused waiting for a kick.

.. code-block:: c

    applier_f
        ...
        applier_connect
            ...
            applier_set_state(applier, APPLIER_CONNECTED);
            ...
        if (tt_uuid_is_nil(&REPLICASET_UUID))
            applier_join(applier);

Side note: there are two triggers assigned to ``applier->on_state``.
The first one is new ``applier_on_state_f`` and second is
``replica_on_applier_state_f``. The triggers are running in the sequence
above but neet to mention than ``applier_on_state_f`` is one time trigger,
once fired it get cleaned up while ``replica_on_applier_state_f`` is premanent.
And to refresh memory these triggers are running from
``applier_f: applier_set_state``.

The ``applier_resume_to_state`` kicks the applier of a chosen leader.
This fiber tries to pass authentification (if provided in config) and become
``APPLIER_READY``.

.. code-block:: c

    applier_on_state_f
        if (applier->state != APPLIER_OFF &&
            applier->state != APPLIER_STOPPED &&
            applier->state != on_state->desired_state)
            return;
        fiber_cond_signal(&on_state->wakeup);
        applier_pause(applier);

In other words ``applier_resume_to_state`` kicks the applier
and waits it to reach the desired state then simply pause.
And stages are processed one by one. At every stage two triggers
are running as been mentioned above.

Once applier reaches ``APPLIER_READY`` we wait it to pass
the join stage.

.. code-block:: c

    applier_join
        xrow_encode_join_xc(&row, &INSTANCE_UUID);
        coio_write_xrow(coio, &row);
        xrow_decode_vclock_xc(&row, &replicaset.vclock);
        applier_set_state(applier, APPLIER_INITIAL_JOIN);

Note that we fetch vclock from a cluster leader and save it
into ``replicaset.vclock``.

The ``applier_set_state(APPLIER_INITIAL_JOIN)`` triggers
``applier_resume_to_state`` to process.

.. code-block:: c

    replica_on_applier_state_f(struct trigger *trigger, void *event)
        ...
        case APPLIER_INITIAL_JOIN:
            replicaset.is_joining = true;
            break;
        case APPLIER_JOINED:
            replicaset.is_joining = false;
            break;
        ...
        fiber_cond_signal(&replicaset.applier.cond);

So back to ``bootstrap_from_master`` we wait the applier to
pass ``APPLIER_INITIAL_JOIN``, where we receive vclock from
the cluster leader. Then we kick ``applier_join`` to process

.. code-block:: c

    applier_join
        while (true) {
            coio_read_xrow(coio, ibuf, &row);
            if (iproto_type_is_dml(row.type)) {
                xstream_write_xc(applier->join_stream, &row);
            } else if (row.type == IPROTO_OK) {
                break;
            }
            ...
            applier_set_state(applier, APPLIER_FINAL_JOIN);

So we receive data manipulation requests (ie records with operation
and data, an remember them in applier ``join_stream``). The reply
``IPROTO_OK`` means we are done with joining to the cluster leader.
The applier sets ``APPLIER_FINAL_JOIN`` state and notifies
``bootstrap_from_master`` about passing this stage.
Remember after each notification the applier get paused.

Then the main fiber continue until ``APPLIER_READY`` is reached

.. code-block:: c

    bootstrap_from_master(struct replica *master)
        ...
        engine_begin_final_recovery_xc();
        recovery_journal_create(&journal, &replicaset.vclock);
        journal_set(&journal.base);
        applier_resume_to_state(applier, APPLIER_JOINED);
        engine_end_recovery_xc();
        applier_resume_to_state(applier, APPLIER_READY);

Before the applier become ``APPLIER_READY`` it receives final
data from cluster leader.

.. code-block:: c

    applier_join
        while (true) {
            coio_read_xrow(coio, ibuf, &row);
            if (iproto_type_is_dml(row.type)) {
                vclock_follow_xrow(&replicaset.vclock, &row);
                xstream_write_xc(applier->subscribe_stream, &row);
            } else if (row.type == IPROTO_OK) {
                break;
            }
            ...
            applier_set_state(applier, APPLIER_JOINED);
            applier_set_state(applier, APPLIER_READY);


FIXME: We need to put details about ``join_stream`` and ``subscribe_stream``
xstreams associated with applier fibers. They are shared between all appliers
and manipulate with backend engine (memtx, vinyl).

Once appliers are ready we do a checkpoint. The appliers are paused
and no longer assigned to ``applier_on_state_f`` trigger.

.. code-block:: c

    bootstrap_from_master
        ...
        do_checkpoint();
        gc_add_checkpoint(&replicaset.vclock);

Next we consider the code which is common for both modes.

Continue bootstrap
~~~~~~~~~~~~~~~~~~

We wake up appliers fibers and try to reconnect the ones
which were unable to connect

.. code-block:: c

    box_cfg_xc
        ...
        replicaset_follow
            replicaset_foreach(replica)
                applier_resume(replica->applier);
            rlist_foreach_entry_safe(replica, &replicaset.anon...)
                applier_start(replica->applier)
        ...

Note that woken appliers are not running they are just marked
as alive.

After waking up all appliers comes the ``sync`` stage:

..  code-block:: c

    box_cfg_xc
        ...
        replicaset_follow
        ...
        replicaset_sync
            ...
            double deadline = ev_monotonic_now(loop()) +
                              replication_sync_timeout;
            while (replicaset.applier.synced < quorum && ...) {
                if (fiber_cond_wait_deadline(&replicaset.applier.cond,
                                             deadline) != 0)
                    break;
            }
            ...
            if (replicaset.applier.synced < quorum) {
                ...
                box_set_orphan(true);
            }

The idea behind ``replicaset_sync`` is to keep the node read-only (by marking it
as an orphan by ``box_set_orphan(true)``) until it syncs with at least
``replication_connect_quorum`` remote nodes. This means that the local node has
received all the data the remote nodes had at the moment of connection and has
managed to catch up with them with a lag not more than ``replication_sync_lag``:

.. code-block:: c

    applier_check_sync
        ...
        if (applier->lag <= replication-sync_lag &&
            vclock_compare(&applier->remote_vclock_at_subscribe,
                           &replicaset.vclock) <= 0) {
             applier_set_state(applier, APPLIER_FOLLOW);

.. code-block:: c

    replica_on_applier_sync
        replicaset.applier.synced++;

The attempts to sync with remote nodes do not stop once the timeout
(``replication_sync_timeout``) expires. Once the timeout is reached the node
leaves ``replicaset_sync`` and ``box_cfg_xc``, but stays orphan (i.e. read-only)
and its appliers continue trying to sync.

If the quorum is synced sooner or later, the node leaves orphan mode and may
become writable.

Applier lifecycle
~~~~~~~~~~~~~~~~~

Next we need them to process further and call ``applier_subscribe``.
The appliers are scheduled to execution by ``box_cfg_xc`` callers,
which is either *interactive console* (where explicit ``fiber_yield``
is called waiting for input from command line) or once startup script is
finished and we call ``ev_run`` which leads to run idle events causing
reschedule to happen.

Once ``applier_subscribe`` executed we try to subscribe
to the **master** node we wanted to receive changed from.

.. code-block:: c

    applier_subscribe(struct applier *applier)
    ...
        /* Send SUBSCRIBE comand */
        vclock_create(&vclock);
        vclock_copy(&vclock, &replicaset.vclock);
        xrow_encode_subscribe_xc(&row, &REPLICASET_UUID,
                &INSTANCE_UUID, &vclock);
        coio_write_xrow(coio, &row);
    
        /* Read SUBSCRIBE response */
        if (applier->version_id >= version_id(1, 6, 7)) {
            coio_read_xrow(coio, ibuf, &row);
            ...
            /*
             * In case of successful subscribe, the server
             * responds with its current vclock.
             */
            vclock_create(&remote_vclock_at_subscribe);
            xrow_decode_vclock_xc(&row, &remote_vclock_at_subscribe);
    
            say_info("subscribed");
            say_info("remote vclock %s local vclock %s",
                vclock_to_string(&remote_vclock_at_subscribe),
                vclock_to_string(&vclock));
        }
        ...

Once we're subscribed we create that named "writer" fiber

.. code-block:: c

    applier_subscribe
        ...
        char name[FIBER_NAME_MAX];
        int pos = snprintf(name, sizeof(name), "applierw/");
        uri_format(name + pos, sizeof(name) - pos, &applier->uri, false);
        applier->writer = fiber_new_xc(name, applier_writer_f);
        fiber_set_joinable(applier->writer, true);
        fiber_start(applier->writer, applier);


This fiber is serving *Ack* commands to send to master node
notifying it with the last vclock value it has successfully
processed.

.. code-block:: c

    applier_writer_f
        while (!fiber_is_cancelled()) {
            if (applier->version_id >= version_id(1, 7, 7))
                fiber_cond_wait_timeout(&applier->writer_cond,
                    TIMEOUT_INFINITY);
            else
                fiber_cond_wait_timeout(&applier->writer_cond,
                    replication_timeout);
            if (applier->state != APPLIER_SYNC &&
                applier->state != APPLIER_FOLLOW)
                    continue;
            struct xrow_header xrow;
            xrow_encode_vclock(&xrow, &replicaset.vclock);
            coio_write_xrow(&io, &xrow);
        }

In case of error the fiber logs the error but continue spinning
until it get explicitly cancled by the applier.

Then the applier enters the loop which waits for data to be received
from the master node. In other words any update on the master node
is sent to us via network and we are trying to update our local
instance with new data.

.. code-block:: c

    applier_subscribe
        ...
        while (true) {
            ...
            if (applier->version_id < version_id(1, 7, 7)) {
                coio_read_xrow(coio, ibuf, &row);
            } else {
                double timeout = replication_disconnect_timeout();
                coio_read_xrow_timeout_xc(coio, ibuf, &row, timeout);
            }
            ...
            applier->lag = ev_now(loop()) - row.tm;
            applier->last_row_time = ev_monotonic_now(loop());
            struct replica *replica = replica_by_id(row.replica_id);
            ...
            if (vclock_get(&replicaset.vclock, row.replica_id) < row.lsn) {
                // Write the changes local if incomin data is newer
                int res = xstream_write(applier->subscribe_stream, &row);
                ...
            }
            if (applier->state == APPLIER_SYNC ||
                applier->state == APPLIER_FOLLOW)
                fiber_cond_signal(&applier->writer_cond);
            ...
        }

Upon new data arrived we figure out if we should apply the change using
``lsn`` as a marker. If the data is more novel that we have now we write
it into local instance (the ``subscribe_stream`` uses ``apply_row`` helper
which process database requests) and send *Ack* packet back to the master
(waking up ``applier->writer_cond`` which triggers ``applier_writer_f`` cycle.

An interesting moment takes place when some error happens inside
``applier_subscribe`` routine - in this case we raise an error via
``diag_raise`` helper (which basically throws an exception). The caller
intercepts it.

.. code-block:: c

    applier_f
        ...
        while (!fiber_is_cancelled()) {
            try {
                applier_subscribe(applier);
                ...
            } catch (...) {
                ...
            }
        }

Depending on error type the ``applier_f`` fiber either try to reconnect
to the master node or simply disconnect (when applier get disconnected
it stops the writer fiber as well) and finish its execution.

Replication in 2.x series
-------------------------

Generally replication in 2.x series very similar to 1.10 in ideas
still there are some significant differences.

The initialization starts with ``box_cfg_xc``.

.. code-block:: c

    box_cfg_xc(void)
        ...
        // prepare replicaset
        replication_init();
        ...
        box_set_replication_anon();

The ``box_set_replication_anon`` serves anonymous replications.
Most important part here is that this code is called by two places:
from the cold start of tarantool and when ``box.cfg{}``} is triggered
manually (from interactive console or script).

Thus if previously the node has been an anonymous replica (where we only
fetch fresh data from the remote master machine) and wanna be a normal
replica then we have to reset all previous appliers and reconnect
to a master. In turn it implies that previously we've finished bootup
with anonymous replication and we have some appliers running.

.. code-block:: c

    void
    box_set_replication_anon(void)
    {
        bool anon = box_check_replication_anon();
        //
        // the role of the node has not been changed
        if (anon == replication_anon)
            return;
        //
        // We were anonymous replica and gonna be
        // a regular one.
        if (!anon) {
            replication_anon = anon;
            box_sync_replication(false);
            struct replica *master = replicaset_leader();
            if (master == NULL || master->applier == NULL ||
                master->applier->state != APPLIER_CONNECTED) {
                tnt_raise(ClientError, ER_CANNOT_REGISTER);
            }
            struct applier *master_applier = master->applier;
            applier_resume_to_state(master_applier, APPLIER_REGISTERED,
                                    TIMEOUT_INFINITY);
            applier_resume_to_state(master_applier, APPLIER_READY,
                                    TIMEOUT_INFINITY);
            replicaset_follow();
            replicaset_sync();
        } else if (!is_box_configured) {
            replication_anon = anon;
        } else {
            tnt_raise(ClientError, ER_CFG, "replication_anon",
                "cannot be turned on after bootstrap"
                " has finished");
        } 

On a cold start if we gonna be an anonymous replica we just remember the
setting in ``replication_anon``. Then we continue bootstrap procedure
(we don't consider local recovery for simplicity sake).

First we're trying to reify appliers.

.. code-block:: c

    bootstrap()
        ...
        box_sync_replication(true);
            appliers = cfg_get_replication(&count);
            replicaset_connect(appliers, ...);
                if (!connect_quorum)
                    box_do_set_orphan(true)
                for (int i = 0; i < count; i++)
                    trigger_create(applier_on_connect_f)
                    applier_start(applier);
                for (int i = 0; i < count; i++)
                    trigger_clear(&triggers[i].base)
                    if (applier->state != APPLIER_CONNECTED)
                        applier_stop(applier);
                replicaset_update(appliers, count)

We connect to remote machines (if quorum is not fit we just leave
the box in read only state) and register replicas in global replicas
hash. If there some old appliers were running we clean them up. This
is similar to 1.10 series. If something goes wrong we trigger an
exception.

Then we continue bootstrap either from remote master node or as
a cluster leader.

Bootstrap first replica
~~~~~~~~~~~~~~~~~~~~~~~

This process is similar to 1.10 series - we register our node
``replica_id`` in ``_cluster`` internal service space together
with other replicas. Then replicaset is registered in the
``_schema`` space.

Bootstrap from a cluster leader
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Booting up from cluster leader a bit differs from 1.10 due to
anonymous replication (the master node is obtained by
``replicaset_leader``)

.. code-block:: c

    static void
    bootstrap_from_master(struct replica *master)
    {
        applier = master->applier;
    
        // Wait the applier becom ready
        applier_resume_to_state(applier, APPLIER_READY, TIMEOUT_INFINITY);
        
        // Either join a cluster or
        // fetch the snapshot.
        wait_state = replication_anon ?
            APPLIER_FETCH_SNAPSHOT :
            APPLIER_INITIAL_JOIN;
        applier_resume_to_state(applier, wait_state, TIMEOUT_INFINITY);
    
        /*
         * Process initial data (snapshot or dirty disk data).
         */
        engine_begin_initial_recovery_xc(NULL);
        wait_state = replication_anon ?
            APPLIER_FETCHED_SNAPSHOT :
            APPLIER_FINAL_JOIN;
        applier_resume_to_state(applier, wait_state, TIMEOUT_INFINITY);
    
        /*
         * Process final data (WALs).
         */
        engine_begin_final_recovery_xc();
        recovery_journal_create(&replicaset.vclock);
    
        if (!replication_anon) {
            applier_resume_to_state(applier, APPLIER_JOINED,
                TIMEOUT_INFINITY);
        }
    
        /* Finalize the new replica */
        engine_end_recovery_xc();
    
        /* Switch applier to initial state */
        applier_resume_to_state(applier, APPLIER_READY, TIMEOUT_INFINITY);
        ...
    }

An interesting moment here is if we boot as an anonymous replica: instead
of joining master we wait the applier (ie ``applier_f``) to fetch a snapshot
of data from remote master node. Same time if we've been an anonymous replica
we try to make a transition to become a regular one.

.. code-block:: c

    static int
    applier_f(va_list ap)
        ...
        while (!fiber_is_cancelled()) {
            try {
                // Connect to remote peers
                applier_connect(applier);
                if (tt_uuid_is_nil(&REPLICASET_UUID)) {
                    // Either join to cluster or
                    // just fetch a data snapshot
                    if (replication_anon)
                        applier_fetch_snapshot(applier);
                    else
                        applier_join(applier);
                }
                if (instance_id == REPLICA_ID_NIL &&
                    !replication_anon) {
                    // We've been an anonymous replica
                    // and become a normal one
                    applier_register(applier);
                }
                applier_subscribe(applier);
            } catch() {
                ...
            }
        }

Then we jump into ``applier_subscribe`` lifecycle.

Applier lifecycle
~~~~~~~~~~~~~~~~~

Processing requests is implemented via ``applier_subscribe`` helper.

.. code-block:: c

    static void
    applier_subscribe(struct applier *applier)
    {
        /* Send SUBSCRIBE request */
        struct ev_io *coio = &applier->io;
        struct ibuf *ibuf = &applier->ibuf;
        struct xrow_header row;
        struct tt_uuid cluster_id = uuid_nil;
    
        struct vclock vclock;
        vclock_create(&vclock);
        vclock_copy(&vclock, &replicaset.vclock);
    
        // Send subscribe command to the master node
        uint32_t id_filter = box_is_orphan() ? 0 : 1 << instance_id;
        xrow_encode_subscribe_xc(&row, &REPLICASET_UUID, &INSTANCE_UUID,
                &vclock, replication_anon, id_filter);
        coio_write_xrow(coio, &row);
    
        /* Read SUBSCRIBE response */
        if (applier->version_id >= version_id(1, 6, 7)) {
            coio_read_xrow(coio, ibuf, &row);
            if (iproto_type_is_error(row.type)) {
                xrow_decode_error_xc(&row);  /* error */
            } else if (row.type != IPROTO_OK) {
                tnt_raise(ClientError, ER_PROTOCOL,
                        "Invalid response to SUBSCRIBE");
            }
            /*
             * In case of successful subscribe, the server
             * responds with its current vclock.
             *
             * Tarantool > 2.1.1 also sends its cluster id to
             * the replica, and replica has to check whether
             * its and master's cluster ids match.
             */
            vclock_create(&applier->remote_vclock_at_subscribe);
            xrow_decode_subscribe_response_xc(&row, &cluster_id,
                    &applier->remote_vclock_at_subscribe);
            /*
             * If master didn't send us its cluster id
             * assume that it has done all the checks.
             * In this case cluster_id will remain zero.
             */
            if (!tt_uuid_is_nil(&cluster_id) &&
                !tt_uuid_is_equal(&cluster_id, &REPLICASET_UUID)) {
                tnt_raise(ClientError, ER_REPLICASET_UUID_MISMATCH,
                    tt_uuid_str(&cluster_id),
                    tt_uuid_str(&REPLICASET_UUID));
            }
    
            say_info("subscribed");
            say_info("remote vclock %s local vclock %s",
                vclock_to_string(&applier->remote_vclock_at_subscribe),
                vclock_to_string(&vclock));
        }
        /*
         * Tarantool < 1.6.7:
         * If there is an error in subscribe, it's sent directly
         * in response to subscribe.  If subscribe is successful,
         * there is no "OK" response, but a stream of rows from
         * the binary log.
         */
    
        if (applier->state == APPLIER_READY) {
            /*
             * Tarantool < 1.7.7 does not send periodic heartbeat
             * messages so we cannot enable applier synchronization
             * for it without risking getting stuck in the 'orphan'
             * mode until a DML operation happens on the master.
             */
            if (applier->version_id >= version_id(1, 7, 7))
                applier_set_state(applier, APPLIER_SYNC);
            else
                applier_set_state(applier, APPLIER_FOLLOW);
        } else {
            /*
             * Tarantool < 1.7.0 sends replica id during
             * "subscribe" stage. We can't finish bootstrap
             * until it is received.
             */
            assert(applier->state == APPLIER_FINAL_JOIN);
            assert(applier->version_id < version_id(1, 7, 0));
        }
    
        /* Re-enable warnings after successful execution of SUBSCRIBE */
        applier->last_logged_errcode = 0;
        if (applier->version_id >= version_id(1, 7, 4)) {
            /* Enable replication ACKs for newer servers */
    
            char name[FIBER_NAME_MAX];
            int pos = snprintf(name, sizeof(name), "applierw/");
            uri_format(name + pos, sizeof(name) - pos, &applier->uri, false);
    
            applier->writer = fiber_new_xc(name, applier_writer_f);
            fiber_set_joinable(applier->writer, true);
            fiber_start(applier->writer, applier);
        }
    
        applier->lag = TIMEOUT_INFINITY;
        ...
    }

First we're trying to subscribe to the remote master node. On success
we crate a writer fiber (which runs ``applier_writer_f``) fiber to
send Acks to remote node upon we commit the data received.

Then we enter applier lifecycle

.. code-block:: c

    static void
    applier_subscribe(struct applier *applier)
    {
        ...
        /* Register triggers to handle replication commits and rollbacks. */
        struct trigger on_commit;
        trigger_create(&on_commit, applier_on_commit, applier, NULL);
        trigger_add(&replicaset.applier.on_commit, &on_commit);
    
        struct trigger on_rollback;
        trigger_create(&on_rollback, applier_on_rollback, applier, NULL);
        trigger_add(&replicaset.applier.on_rollback, &on_rollback);
    
        auto trigger_guard = make_scoped_guard([&] {
            trigger_clear(&on_commit);
            trigger_clear(&on_rollback);
        });
    
        /*
         * Process a stream of rows from the binary log.
         */
        while (true) {
            if (applier->state == APPLIER_FINAL_JOIN &&
                instance_id != REPLICA_ID_NIL) {
                say_info("final data received");
                applier_set_state(applier, APPLIER_JOINED);
                applier_set_state(applier, APPLIER_READY);
                applier_set_state(applier, APPLIER_FOLLOW);
            }
    
            struct stailq rows;
            applier_read_tx(applier, &rows);
    
            applier->last_row_time = ev_monotonic_now(loop());
            /*
             * In case of an heartbeat message wake a writer up
             * and check applier state.
             */
            if (stailq_first_entry(&rows, struct applier_tx_row,
                next)->row.lsn == 0)
                fiber_cond_signal(&applier->writer_cond);
            else if (applier_apply_tx(&rows) != 0)
                diag_raise();
        }
    }

Here we fetch data from remote node via ``applier_read_tx`` and collect
it into ``rows`` queue. Then call ``applier_apply_tx`` to process it
locally (we will back to it). The trigger ``applier_on_commit`` notifies
the writer fiber to send Ack to the remote node. In turn the trigger
``applier_on_rollback`` is a bit more complex

.. code-block:: c

    static int
    applier_on_rollback(struct trigger *trigger, void *event)
    {
        struct applier *applier = (struct applier *)trigger->data;
        /* Setup a shared error. */
        if (!diag_is_empty(&replicaset.applier.diag)) {
            diag_add_error(&applier->diag,
                diag_last_error(&replicaset.applier.diag));
        }
        /* Stop the applier fiber. */
        fiber_cancel(applier->reader);
        return 0;
    }

It runs when something gone wrong when we've been processing the
transaction. We move the error shared between all appliers in
``replicaset.applier.diag``. This is toplevel diag instance. Each
applier has own diag entry as well. We will dive into this moment
a bit later. So we put a reference from ``replicaset.applier.diag``
error to the failing applier diag instace and stop the applier.

Main processing of the transaction takes place in

.. code-block:: c

    static int
    applier_apply_tx(struct stailq *rows)
    {
        ...
        struct txn *txn = txn_begin();
        struct applier_tx_row *item;
        ...
        stailq_foreach_entry(item, rows, next) {
            // process data in engine (box_process_rw)
            int res = apply_row(row);
            ...
            if (res != 0)
                goto rollback;
        }
        ...
        struct trigger *on_rollback, *on_commit;
        on_rollback = region_alloc(&txn->region, ...);
        on_commit = region_alloc(&txn->region, ...);

        trigger_create(on_rollback, applier_txn_rollback_cb, ...);
        txn_on_rollback(txn, on_rollback);
    
        trigger_create(on_commit, applier_txn_commit_cb, ...);
        txn_on_commit(txn, on_commit);
    
        // Write transaction to WAL
        if (txn_commit_async(txn) < 0)
            goto fail;
    
        vclock_follow(&replicaset.applier.vclock,
            first_row->replica_id, first_row->lsn);
        ...
        return 0;
    rollback:
        txn_rollback(txn);
    fail:
        ...
        return -1;
    }

First we try to commit request into engine without writting to
the WAL. If it passes fine we create two triggers -
``applier_txn_commit_cb`` to notify linked triggers that
transaction passed (in our case it means we trigger toplevel
``applier_on_commit`` and applier writer fiber notifies the
master node that transaction has been successfully completed),
and ``applier_txn_rollback_cb`` to rollback the commit.

The ``applier_txn_rollback_cb`` is a bit tricky. It sets
error to the current fiber and copies it to the replicaset
instance.

.. code-block:: c

    static int
    applier_txn_rollback_cb(struct trigger *trigger, void *event)
    {
        (void) trigger;

        /* Setup shared applier diagnostic area. */
        diag_set(ClientError, ER_WAL_IO);
        diag_set_error(&replicaset.applier.diag,
                       diag_last_error(diag_get()));

        /* Broadcast the rollback event across all appliers. */
        trigger_run(&replicaset.applier.on_rollback, event);

        /* Rollback applier vclock to the committed one. */
        vclock_copy(&replicaset.applier.vclock, &replicaset.vclock);
        return 0;
    }

Then we run chained ``on_rollback`` which is basically
``applier_txn_rollback_cb`` set earlier.

Once transaction is prepared we call ``txn_commit_async`` to write
it into WAL. The write is done in asynchronous manner which means
it simply queued but not written immediately. Because of this
the triggers were allocated dynamically since we can't use
stack space for deferred writes.

The transaction itself bound to journal entry thus the caller
fiber no longer linked with it. The calling fiber simply goes
into next iteration and waits for data to receive from remote
node.

The WAL engine will commit the transaction by self independently
of the applier fiber. An interesting moment here is how we rollback
the transaction if something went wrong. The core function here is

.. code-block:: c

    static void
    txn_complete(struct txn *txn)
    {
        if (txn->signature < 0) {
            /* Undo the transaction. */
            struct txn_stmt *stmt;
            stailq_reverse(&txn->stmts);
            stailq_foreach_entry(stmt, &txn->stmts, next)
                txn_rollback_one_stmt(txn, stmt);
            if (txn->engine)
                engine_rollback(txn->engine, txn);
            if (txn_has_flag(txn, TXN_HAS_TRIGGERS))
                txn_run_rollback_triggers(txn, &txn->on_rollback);
        ...
        }
    }

When we run ``txn_run_rollback_triggers`` we call the linked
trigger ``applier_txn_rollback_cb`` mentioned recently where
we copy error into shared ``replicaset.applier.diag`` and
run ``replicaset.applier.on_rollback``, which in turn calls a
linked ``applier_on_rollback``. This fetches last error from
``relicaset`` instance, sets it to the current applier and
then stops the applier fiber.
