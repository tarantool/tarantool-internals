:html_theme.sidebar_secondary.remove:

.. _cbus:

Cbus (Communication bus)
========================


Introduction
------------

Cbus serves as a way to communicate between cords. It's widely used in
description of the :ref:`replication` and :ref:`relay` internal work.
So, here's an overview of its basic API and architecture.


General overview
----------------

Basically, ``cbus`` is just a shared between all cords singleton with the
following structure:

.. code-block:: c

    /* lib/core/cbus.c */
    struct cbus {
         /** cbus statistics */
         struct rmean *stats;
         /** A mutex to protect bus join. */
         pthread_mutex_t mutex;
         /** Condition for synchronized start of the bus. */
         pthread_cond_t cond;
         /** Connected endpoints */
         struct rlist endpoints;
    };

It provides the user with the message consumers (endpoints) and the way for
producers to connect to these endpoints (pipes). Messages on their own
includes routes, according to which they are delivered by ``cbus_loop`` or
``cbus_process``. Let's consider in details the aforementioned entities.

Endpoints
---------

Cbus endpoint works as a message (event) consumer, which must have a unique
name as all endpoints are saved in ``rlist`` structure of the ``cbus``
singleton. The name is used to identify the endpoint when establishing a
route. Endpoint has the following structure:

.. code-block:: c

    /* lib/core/cbus.h */
    struct cbus_endpoint {
        char name[FIBER_NAME_MAX];
        /** Member of cbus->endpoints */
        struct rlist in_cbus;
        /** The lock around the pipe. */
        pthread_mutex_t mutex;
        /** A queue with incoming messages. */
        struct stailq output;
        /** Consumer cord loop */
        ev_loop *consumer;
        /** Async to notify the consumer */
        ev_async async;
        /** Count of connected pipes */
        uint32_t n_pipes;
        /** Condition for endpoint destroy */
        struct fiber_cond cond;
    };

Endpoint can be created via ``cbus_endpoint_create``:

.. code-block:: c

    /* lib/core/cbus.c */
    int
    cbus_endpoint_create(struct cbus_endpoint *endpoint, const char *name,
                         void (*fetch_cb)(...), void *fetch_data)
    {
        ...
        snprintf(endpoint->name, sizeof(endpoint->name), "%s", name);
        endpoint->consumer = cord()->loop;
        ...
        ev_async_init(&endpoint->async, fetch_cb);
        endpoint->async.data = fetch_data;
        ev_async_start(endpoint->consumer, &endpoint->async);

        /* Register in singleton */
        rlist_add_tail(&cbus.endpoints, &endpoint->in_cbus);

        /* Alert producers */
        tt_pthread_cond_broadcast(&cbus.cond);
        tt_pthread_mutex_unlock(&cbus.mutex);
        return 0;
    }

The function expects ``fetch_cb``, which is a callback to fetch new messages.
It's registered as an ``ev_async`` watcher (see ``man libev``). As soon as all
fields of the endpoint are initialized and it's added to the ``cbus``
registry, ``cbus_endpoint_create`` wakes up all producers (pipes), which are
blocked waiting for this endpoint to become available.

Endpoint can be destroyed only when no associated producers remains and its
queue with incoming messages is empty:

.. code-block:: c

    /* lib/core/cbus.c */
    int
    cbus_endpoint_destroy(struct cbus_endpoint *endpoint,
                  void (*process_cb)(struct cbus_endpoint *endpoint))
    {
        tt_pthread_mutex_lock(&cbus.mutex);
        rlist_del(&endpoint->in_cbus);
        tt_pthread_mutex_unlock(&cbus.mutex);

        while (true) {
            if (process_cb)
                process_cb(endpoint);
            if (endpoint->n_pipes == 0 && stailq_empty(&endpoint->output))
                break;
             fiber_cond_wait(&endpoint->cond);
        }
        ...
        ev_async_stop(endpoint->consumer, &endpoint->async);
        ...
        return 0;
    }


Cpipes (communication pipes)
----------------------------

The cpipe serves as a uni-directional FIFO queue from one cord to another.
It works as a message (event) producer and has the following structure:

.. code-block:: c

    /* lib/core/cbus.h */
    struct cpipe {
        /** Staging area for pushed messages */
        struct stailq input;
        /** Counters are useful for finer-grained scheduling. */
        int n_input;
        /**
         * When pushing messages, keep the staged input size under
         * this limit (speeds up message delivery and reduces
         * latency, while still keeping the bus mutex cold enough).
         */
        int max_input;
        struct ev_async flush_input;
        /** The event loop of the producer cord. */
        struct ev_loop *producer;
        /**
         * The cbus endpoint at the destination cord to handle
         * flushed messages.
         */
        struct cbus_endpoint *endpoint;
        /**
         * Triggers to call on flush event, if the input queue
         * is not empty.
         */
        struct rlist on_flush;
    };

It can be created via ``cpipe_create``:

.. code-block:: c

    /* lib/core/cbus.c */
    void
    cpipe_create(struct cpipe *pipe, const char *consumer)
    {
        stailq_create(&pipe->input);

        pipe->n_input = 0;
        pipe->max_input = INT_MAX;
        pipe->producer = cord()->loop;

        ev_async_init(&pipe->flush_input, cpipe_flush_cb);
        pipe->flush_input.data = pipe;
        rlist_create(&pipe->on_flush);

        tt_pthread_mutex_lock(&cbus.mutex);
        struct cbus_endpoint *endpoint =
            cbus_find_endpoint_locked(&cbus, consumer);
        while (endpoint == NULL) {
            tt_pthread_cond_wait(&cbus.cond, &cbus.mutex);
            endpoint = cbus_find_endpoint_locked(&cbus, consumer);
        }
        pipe->endpoint = endpoint;
        ++pipe->endpoint->n_pipes;
        tt_pthread_mutex_unlock(&cbus.mutex);
    }

As we can see the function waits until the needed endpoint appears in ``cbus``
registry. This is why we alerted all producers in ``cbus_endpoint_create``.

``cpipe_flush_cb`` watcher is also registered here. It flushes messages
from the ``pipe->input`` to the ``pipe->endpoint->output``. Note, that
it is invoked not only once per loop iteration but also when ``max_input``
is reached:

.. code-block:: c

    /* lib/core/cbus.c */
    static inline void
    cpipe_push_input(struct cpipe *pipe, struct cmsg *msg)
    {
        assert(loop() == pipe->producer);

        stailq_add_tail_entry(&pipe->input, msg, fifo);
        pipe->n_input++;
        if (pipe->n_input >= pipe->max_input)
            ev_invoke(pipe->producer, &pipe->flush_input, EV_CUSTOM);
    }


Event loop and messages
-----------------------

In order to enter the message processing loop ``cbus_loop`` can be used:

.. code-block:: c

    /* lib/core/cbus.c */
    void
    cbus_loop(struct cbus_endpoint *endpoint)
    {
        while (true) {
            cbus_process(endpoint);
                // cbus_process() code
                struct stailq output;
                stailq_create(&output);
                cbus_endpoint_fetch(endpoint, &output);
                struct cmsg *msg, *msg_next;
                stailq_foreach_entry_safe(msg, msg_next, &output, fifo)
                    cmsg_deliver(msg);

            if (fiber_is_cancelled())
                break;
            fiber_yield();
        }
    }

The ``cbus_process`` above fetches message from an endpoint's queue and
process them with ``cmsg_deliver``.

Every message traveling between cords has the following structure:

.. code-block:: c

    /* lib/core/cbus.h */
    struct cmsg {
        /**
         * A member of the linked list - fifo of the pipe the
         * message is stuck in currently, waiting to get
         * delivered.
         */
        struct stailq_entry fifo;
        /** The message routing path. */
        const struct cmsg_hop *route;
        /** The current hop the message is at. */
        const struct cmsg_hop *hop;
    };

     struct cmsg_hop {
         /** The message delivery function. */
         cmsg_f f;
         /**
          * The next destination to which the message
          * should be routed after its delivered locally.
          */
         struct cpipe *pipe;
     };

A message may need to be delivered to many destinations before it can
be dispensed with. For example, it may be necessary to return a message
to the sender just to destroy it.

Message travel route is an array of cmsg_hop entries. The first
entry contains a delivery function at the first destination,
and the next destination. Subsequent entries are alike. The
last entry has a delivery function (most often a message
destructor) and NULL for the next destination.

As in ``cbus_process`` we deal with already delivered messages, in
``cmsg_deliver`` we invoke the message delivery function ``f`` of the
current hop and dispatch it to the next hop.

.. code-block:: c

    /* lib/core/cbus.c */
    void
    cmsg_deliver(struct cmsg *msg)
    {
        struct cpipe *pipe = msg->hop->pipe;
        msg->hop->f(msg);
        cmsg_dispatch(pipe, msg);
            /* cmsg_dispatch() code */
            if (pipe) {
                msg->hop++;
                cpipe_push(pipe, msg);
            }
    }
