.. vim: ts=4 sw=4 et

MVCC in memtx
=============

Introduction
------------

This section shows a rough explanation of MVCC in Tarantool, which will be
handy to have in mind before digging into its implementation details.

MVCC is a facility allowing to execute multiple transactions concurrently.
All transactions in Tarantool are executed on one thread (TX), but due to the
cooperative multitasking they can yield the control one to another. A yield
inside a transaction is allowed only with MVCC: without it the memtx engine
takes the permission away when the transaction begins, and the transaction is
aborted on the first yield (``memtx_engine_begin()``, ``txn_on_yield()``),
because the yield would expose its uncommitted changes to the others. With
MVCC the transaction keeps its own view of the data across a yield, so a long
lasting transaction can be executed concurrently with fast ones if it yields
once in a while.

The problem with this facility is that conflicts between transactions are
possible. In general, a transaction must see the data it's working with in a
consistent state. That means two things:

1. If a transaction once read a tuple by a key, it must see the same tuple at
   this key for the rest of its life (up until it's committed or rolled
   back).
2. There must be a theoretical point in time where the transaction could be
   executed the way it has been executed and see the database in the state it
   has seen.

The database state includes data from different indexes and spaces. If a
transaction has:

- read a ``tuple_1`` by ``key_1`` in the ``space_1``;
- read ``tuple_2``, which is the first tuple greater than ``key_2`` in the
  ``space_2``;
- found out that there's no ``key_3`` in the ``space_3``,

it can safely assume that for the rest of the transaction:

- ``tuple_1`` still exists at ``key_1`` in the ``space_1``;
- ``tuple_2`` is still the first tuple greater than ``key_2`` in
  ``space_2``;
- and there's still no ``key_3`` in the ``space_3``.

If any of its assumptions are broken (for example someone replaced
``tuple_1`` with ``tuple_1a`` at ``key_1`` in ``space_1``), then the two
transactions are conflicted and we have a bunch of options of what to do next,
see :ref:`memtx-tx-conflicts` for more details on memtx conflicts and how
they're handled. Actually, all of MVCC boils down to maintaining the state
visible to a transaction and conflicting it when required.

.. _memtx-tx-conflicts:

Memtx TX conflicts
------------------

There are a number of ways transactions may conflict:

1. Someone deletes the tuple someone else has read:

   ..  code:: lua

       tx1.index:get({1})    -- {1}
       tx2.index:delete({1}) -- conflict, tx1 had read the key we delete.

2. Someone looks up in a space by a key, and another one inserts a new
   matching tuple:

   ..  code:: lua

       tx1.index:select({0}, {iterator = 'GE'}) -- {} (nothing found)
       tx2.index:insert({1}) -- conflict, the inserted key matches the
                             -- one tx1 had requested and found nothing.

3. Someone replaces the tuple someone else has read:

   ..  code:: lua

       tx1.index:get({1})         -- {1, 37}
       tx2.index:replace({1, 73}) -- conflict, tx1 had read the key we
                                  -- replace.

In case of a conflict we have two transactions: a breaker and a victim. The
breaker is the one whose write caused the conflict: it overwrote or deleted a
value that someone had read, or inserted a tuple into a place where someone
had found nothing. The breaker never suffers from this conflict. Everyone who
read the broken value or gap is a victim.

The conflict is not resolved at the moment of the write, but when the breaker
prepares its statement, that is, when the change is about to become permanent.
Then the victim either goes to a read view or is aborted:

1. If the victim has already written a statement, it is aborted: it could not
   commit from a read view anyway.
2. If the victim is read-only, it is moved to a (possibly deeper) read view,
   where it keeps seeing the state it has read.

A conflict therefore always involves a write: two transactions can only
conflict if at least one of them is writing. Two writes to the same tuple do
not conflict by themselves. If a transaction replaces a tuple that another one
has also replaced and neither of them has read it, their stories just coexist
in the chain, ordered by psn, and the one prepared later is the one visible
afterwards. The exception is a duplicate in a unique index: two transactions
inserting different tuples that collide by a secondary key conflict, and the
in-progress one that would create the duplicate is aborted when the other
prepares.

A few more rules:

1. A transaction in a read view cannot write: a statement started there aborts
   the transaction.
2. Aborting a transaction aborts everyone who read the values it wrote: their
   reads are based on a state that will never exist.
3. Sometimes a conflict is caused not by a write of a matching value, but by
   an insertion or a deletion alone. If tx1 counted three tuples (``{1}``,
   ``{2}`` and ``{3}``), a replace of ``{2}`` might not cause a conflict,
   since it does not break the state tx1 is in: it still counts the same
   number of tuples:

   ..  code:: lua

       tx1.index:count({0}, {iterator = 'GE'}) -- 3: {1}, {2}, {3}.
       tx2.index:replace({2}) -- might not conflict, the count is still 3
                              -- for tx1.

General overview
----------------

As mentioned above, in general we only have a few things to consider:

- the read set (the tuples the transaction has read);
- the read gaps (the keys the transaction attempted to read by and got
  nothing, these are index-specific as keys are);
- the write set (the tuples the transaction has written).

The read set is maintained simply: every read goes through the
``memtx_tx_index_entry_clarify`` function. An index entry is a tuple plus
some key data; in a multikey or a functional index one tuple can produce
several entries, so the entry, not the tuple, is what a transaction reads and
what the history keeps. The function finds the version of the entry that is
visible to the transaction performing the read, and adds this transaction
into the list of readers of that version. So for each story there's a set of
reading transactions stored in ``memtx_story::reader_list``. Also there's a
dedicated field in the transaction struct for storing its read set (``struct
txn::read_set``).

For an ordinary index (neither multikey nor functional) an entry is just a
tuple, so there is a small wrapper ``memtx_tx_tuple_clarify``.

Both clarify functions have ``_rw`` variants, used by statements that write.
They always see prepared changes of other transactions, no matter what the
isolation level is. The reason is that a prepared transaction has already
written its changes to the WAL, and from that moment it must be able to
commit: nobody can abort it anymore. So a statement that is going to write
must see such changes at once. If it ignored them, it would build its change
on top of a state that is about to become permanent, and the conflict would
be found too late, when the prepared transaction can no longer be rolled
back. A statement that only reads is allowed to ignore them: when the
prepared transaction commits, the reader is simply moved into a read view.

The read gaps are collected in a bit more sophisticated manner: they're stored
as gap items in the story links (``memtx_story_link::read_gaps``) and in
``index->read_gaps``. There are a few types of such items in the system:

1. ``GAP_INPLACE``.
2. ``GAP_NEARBY``.

Also there are gap items that don't exactly represent read gaps, but rather
operations performed on indexes. These can only be found in
``index->read_gaps``:

1. ``GAP_FULL_SCAN``.
2. ``GAP_COUNT``.

The write sets are not stored explicitly, but the concept of stories,
mentioned above, can be used in order to track modifications performed on a
tuple in an index. This concept is explained in the "Story chains" section
below.

Successors and their use
------------------------

Typically tracking of key access is done using interval trees, this allows
checking whether operations conflict (for example, an inserted key matches a
key range read by a concurrent transaction). But this approach performs the
checks with logarithmic complexity, while the memtx TX manager was created
with a goal of getting O(1) for all operations, given the amount of concurrent
transactions is small (in-memory transactions are meant to be fast).

In order to approach the O(1) complexity when checking for key collisions with
concurrent transactions the successor-based system was introduced. The idea is
simple:

1. Once an element is inserted into a memtx tree index, its successor in the
   index can be returned by the insertion method for free.
2. We can store some information in it, for example, the unsuccessful attempts
   to read tuples by key prior to that element.
3. So we can use this information to find conflicts in O(1) complexity.

Consider the following example:

1. TX1 selects tuples matching ``>= 1`` and gets ``{2}`` and ``{3}``, so we
   leave in the story link of ``{2}`` a ``GAP_NEARBY`` item saying that for TX1
   there was no element matching ``>= 1`` before ``{2}``.
2. TX2 concurrently inserts ``{1}``. It sees in its successor (which is
   ``{2}``) that TX1 requested tuples from the index and hadn't found tuples
   matching ``>= 1`` prior to ``{2}``. But we have just inserted ``{1}`` and
   it matches the key, so we have a conflict with TX1 here.

Just like that we have found a conflict of TX2 with TX1 and can handle it. The
good thing is that whether TX1 also requested data from other places in the
index does not affect this specific conflict: it's found in-place.

The example tracks only the first gap of a range scan. A range scan (``GE``,
``GT``, ``LE``, ``LT``) is not one gap but a chain of ``GAP_NEARBY`` items.
The gap before the first returned tuple carries the read key when the scan
starts before that tuple; the gaps between the returned tuples carry an empty
key and therefore match any insertion; the tail gap has no successor and lives
in ``index->read_gaps``. So for TX1 above an insert of ``{4}`` conflicts as
well. The mechanics are described in :ref:`memtx-tx-gap-items`.

.. _memtx-tx-gap-items:

Gap items
---------

The gap items are directly or indirectly created on various operations on the
index. The directly created ones are: ``GAP_NEARBY``, ``GAP_FULL_SCAN`` and
``GAP_COUNT``. The ``GAP_INPLACE`` is either created lazily after an index
calls ``memtx_tx_track_point`` or when an insertion matches a ``GAP_NEARBY``
item (both cases are described below).

**GAP_INPLACE**

This gap item is an object that informs about the fact that some transaction
has read by a key matching this story and has found nothing. That means that
the story author conflicts with it.

This item is created in a number of cases.

1. The first case is an explicit call of the ``memtx_tx_track_point`` function.
   In this case the TX manager saves the fact that a transaction has found
   nothing equal to a full key in a structure called "point holes" (see
   :ref:`memtx-tx-point-holes`). When an insertion matches such a point hole,
   ``memtx_tx_handle_point_hole_write()`` calls
   ``memtx_tx_track_story_gap()`` and the ``GAP_INPLACE`` item appears in the
   read gaps of the new story, just like the nearby-gap path below.
2. The second case is the insertion of a new element into an index (not only
   for the current transaction, but a new element for all concurrent
   transactions). In case we insert an element into the index prior to a
   successor and it turns out it matches a ``read_gaps`` entry of type
   ``GAP_NEARBY`` of its successor (or the index, if the inserted element is
   the last in the index), the ``GAP_INPLACE`` gap item is created in its
   ``read_gaps``, so now the transaction conflicts with the one that created
   the ``GAP_NEARBY``.

**GAP_NEARBY**

The gap is created using a dedicated function: ``memtx_tx_track_gap``. This
gap item represents the fact that a transaction hasn't found a tuple prior to
a specific successor (or until the end of an index). The item is placed in the
successor's story, or in ``index->read_gaps`` if there is no successor, and the
insertion path checks both lists (``memtx_tx_handle_gap_write()``). Once a new
tuple is inserted into an index prior to that successor (or at the end of the
index), it's compared with the key specified in the gap item, and if it
matches, the story of the new tuple is marked with the ``GAP_INPLACE`` item.

A range scan (``GE``, ``GT``, ``LE``, ``LT``) leaves a chain of such items
rather than one. If the scan starts before the first returned tuple, the first
step of the iterator (``tree_iterator_start()``) tracks a gap with the read
key before that tuple; every following step tracks a gap with an empty key
between the tuple it leaves and the next one, and an empty key matches any
inserted tuple (``memtx_tx_tuple_matches()``); the exhausted step has no
successor, so its item goes into ``index->read_gaps`` and catches inserts
after the last returned tuple.

**GAP_FULL_SCAN**

This gap item is created on an iterator-based lookup in an unordered index
(hash). This item causes a transaction conflict on any insertion into the
index after the iterator is created. Such items are only placed in the index
the lookup is performed in (the one ``memtx_tx_track_full_scan`` is called
in).

**GAP_COUNT**

The gap item is created in case a transaction performs a count of tuples in an
index by a key (``memtx_tx_track_count``). Once such an item is created for a
transaction, any following insertion or deletion of a matching key in the index
will conflict with it (also it will conflict with all the previously created
concurrent modifications, not only inserts and deletes, of matching tuples).

A count can also be bounded (``memtx_tx_track_count_until``): when the matching
tuples are skipped without being read, as in a select with an ``offset``, the
item remembers the tuple the count stops at (``struct count_gap_item::until``
with its hint ``until_hint``, which is referenced for a functional key). A
modification conflicts with such an item only if the changed tuple matches the
key and the iterator up to that bound (``memtx_tx_tuple_matches_until()``).

.. _memtx-tx-point-holes:

Point holes
-----------

The point holes storage is used in order to save point hole entries created
using the ``memtx_tx_track_point`` function. These entries are used and
removed from the storage once a matching tuple is inserted into the index.
