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

Schema changes are the exception to the read-view rule. DDL cannot wait for a
read view: the history the reader would need is about to be deleted, so DDL
aborts its readers instead (see :ref:`memtx-tx-ddl`).

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
tuple in an index. This concept is explained in :ref:`memtx-tx-story-chains`.

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

.. _memtx-tx-story-chains:

Story chains
------------

The write set is not stored anywhere as a list. Instead, every tuple that some
transaction has changed gets a history: a chain of ``struct memtx_story``
objects. One story is one change of the tuple (an insertion, a replacement or
a deletion), and the chain tells in which order these changes happened. A
tuple that nobody has changed yet may have a chain of a single story, which is
simply the state that is in the index now.

A chain describes one index entry, not the tuple as a whole. In a multikey or a
functional index one tuple produces several entries, and each of them is a
separate thing to conflict on. So a story keeps a set of links for each index:
``struct memtx_story::link[index_id]`` is a
``struct memtx_story_index_links``, that is, a list of links plus one inline
slot for the common case when there is only one. Every link of that list
belongs to exactly one chain, that is, to one index entry, and remembers which
entry it is (``key_data``).

The chain is not built in full at once. When a clean tuple is read or replaced,
the TX manager creates only the link it needs: ``memtx_tx_story_link_get()``
takes the entry the caller works with and builds the missing link from its key
data. Operations that walk or rewrite all entries of a story create all the
links first with ``memtx_tx_story_add_index_links()``: one link per multikey
key, one per functional key.

An entry can be absent from an index, and then it has no link. This happens
for two reasons. First, a key part with the ``exclude_null`` option makes the
index skip tuples with ``NULL`` in that part. Second, a multikey index may
have no entry for a tuple: its multikey array may be empty, missing or
``NULL``. A functional index may likewise produce no key, and in either kind
of index a key may be excluded by ``exclude_null``. ``memtx_tx_story_new()``
links a regular index only for a non-excluded tuple,
``memtx_tx_story_add_link()`` assumes the entry is not excluded, and
``memtx_tx_story_add_index_links()`` skips excluded positions and keys. A
story can therefore have fewer links than ``index_count``, up to no link at
all in an index — an "empty story" for that index
(``story->link[i].first.story == NULL`` and an empty list). Reads and writes
through that index never see the tuple, so there is nothing to conflict on
there. The empty link list is a valid state: code that walks every link of a
story (GC, DDL, the snapshot cleaner) simply does nothing for that index.

Links of one chain point to each other with ``newer_link`` and ``older_link``.
The newest link describes the current state of the key. If the tuple is still
in the index, it is this link that has ``in_index`` set to the index; all the
older links have ``in_index`` equal to ``NULL``. The newest link is also the
only one that carries up-to-date ``read_gaps``; for the older links this list
is empty.

The chain is ordered by psn (prepare sequence number, assigned to a transaction
when it prepares), so it goes from the newest stories to the oldest ones: first
the stories of in-progress transactions (``add_psn == 0``), then the stories
of prepared ones (``add_psn != 0``), then the stories of committed ones
(``add_stmt == NULL``), and the last are the stories created by transactions
that were rolled back.

A link also tells whether the change is the transaction's own
(``is_own_change``). This is the case when a transaction rewrote a tuple that
it had written or removed itself, so nobody else could see the key in between.
For a functional index the link owns the key it stores, and ``is_func`` says
so.

GC walks all the stories one at a time: ``memtx_tx_story_gc_step()`` takes the
next story under the cursor ``txm.traverse_all_stories`` and decides whether it
can be freed. The reference point is the psn of the oldest read view, that is,
the ``rv_psn`` of the head of ``read_view_txs`` (or, if there are no read
views, the psn that the next transaction will get). A story survives the step
if:

1. some transaction uses it directly: it has an ``add_stmt``, a ``del_stmt`` or
   at least one reader;
2. a read view may still need it: ``add_psn`` or ``del_psn`` is not less than
   the psn of the oldest read view;
3. some link of it holds gap trackers;
4. it cannot be unlinked without breaking the chains: the story is the top link
   of a chain that has an older link (the older one would become the top while
   not being in the index), or, in a secondary index, the newer story has not
   committed yet and may roll back, in which case this story becomes the top
   again.

Only a story that survives none of these checks is unlinked and deleted. So
being older than every read view makes a story a candidate for collection, not
garbage yet.

Statements and stories
----------------------

A statement keeps a pointer to the story it added (``stmt->add_story``) and a
list of the stories it deleted (``stmt->del_stories``). The stories keep the
pointers back: ``add_stmt`` and ``del_stmt``.

The deleted side is a list on both ends because a deletion can change hands. A
story may be deleted by several transactions at once, none of them knowing
about the others, and when a prepared change becomes visible or is rolled back,
a pending deletion is moved from the old story to the new one, or back.

The element that links the two sides is ``struct memtx_del_story_link``: one
object per pair of a statement and a story it deletes. Its ``next`` field
chains the stories deleted by one statement, ``next_del_stmt`` chains the
statements that deleted the same story, and the first of them is
``story->del_stmt``. One object sits on both lists at once, so dropping a
deletion means unlinking it twice, which is what
``memtx_tx_story_unlink_deleted_by()`` does; the opposite operation is
``memtx_tx_story_link_deleted_by()``.

Read trackers
-------------

Each read of an index entry is tracked by memtx indexes using the
``memtx_tx_index_entry_clarify`` function. Here "clarify" means "give me the
version of the entry that I am allowed to see". The function also saves the
fact that the entry has been read by a transaction. This is done using linked
lists of ``struct tx_read_tracker`` objects stored in the tuple stories
(``struct memtx_story::reader_list``) and in transactions (``struct
txn::read_set``).

So the tracker has two links: ``in_read_set`` (linking into the corresponding
transaction list) and ``in_reader_list`` (linking into the reader list of the
story it is read from).

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

Rollback
--------

A rolled-back statement produced no change, so the story it added must stop
being visible. It cannot be deleted right away, though: it may still be
referenced by read trackers and by its neighbours in the history chains, and
those references must stay valid until the GC removes it.

``memtx_tx_history_rollback_added_story()`` first sinks the story to the end of
every chain it belongs to, in every index (``memtx_tx_story_link_reorder()``),
so that the versions above it become the ones visible to the readers. The
story itself is not deleted yet: it stays at the end of the chains and is
removed later by the GC.

If the statement belonged to a prepared transaction, there is more to undo,
because prepare has already made the change visible to the others. In that
case the function also:

- relinks the in-progress transactions that were deleting the new version
  back to the old one, or to nothing if there was no old version. Prepare had
  moved them, so rollback moves them the other way
  (``memtx_tx_story_unlink_deleted_by()``, then
  ``memtx_tx_story_link_deleted_by()``);
- resets ``add_psn`` to 0 and, if there was an old version, ``del_psn`` of the
  old version to 0, because nothing is prepared anymore;
- aborts with a conflict every transaction that read the story
  (``memtx_tx_abort_story_readers()``): they have seen a version that never
  existed, and no read view can make that state consistent;
- if there was an old version, rechecks what the rollback changes in the
  indexes (``memtx_tx_handle_dups_and_gaps_on_rollback()``): a newer
  in-progress transaction may now duplicate the old version in a secondary
  index, and a transaction that found nothing where the new version had
  appeared is aborted. Both kinds of conflict are found by walking the chain
  up from the old version.

Finally the statement is unlinked from the story it added
(``memtx_tx_story_unlink_added_by()``) and from the story it deleted
(``memtx_tx_story_unlink_deleted_by()``), and the story is marked as deleted
long ago: its ``del_psn`` becomes ``MEMTX_TX_ROLLBACKED_PSN``, which is 1, a
value below ``TXN_MIN_PSN`` and thus below any real psn. No reader can see the
story anymore.

.. _memtx-tx-ddl:

DDL
---

DDL changes the schema of a space and with it the meaning of every MVCC object
bound to that schema: stories, links, read trackers, gap items and point
holes. The manager does not migrate them. Instead, it aborts every concurrent
transaction that may still depend on the old schema and destroys the old
history.

The on-replace trigger for system-space rows
(``on_replace_dd_system_space()`` in ``schema.cc``) calls
``memtx_tx_acquire_ddl()`` before the row is replaced. The function marks the
transaction (``txn::is_schema_changed``) and forbids it to yield once the
schema has changed. When the space cache is replaced,
``space_cache_replace()`` installs the new space and then invalidates the old
one; for memtx this reaches ``memtx_tx_invalidate_space(old_space,
ddl_owner)``, which rebuilds the MVCC state before the old space is freed:

1. ``memtx_tx_abort_space_schema_readers()`` aborts the readers of the space's
   stories (``memtx_story::reader_list``), the gap readers on the top links of
   the chains and in ``index->read_gaps``, every writer with a statement over
   the space (walking the global ``txns`` list), and every point-hole holder
   for its indexes.
2. The indexes are refilled with the tuples visible to ``ddl_owner``
   (``memtx_tx_story_link_find_visible_entry()`` with ``is_prepared_ok =
   true``, then ``memtx_index_replace_entry()``). For the primary index, the
   tuple's primary-index ownership moves to the story of the visible tuple
   (``memtx_tx_ref_to_primary()``, ``memtx_tx_unref_from_primary()``).
3. All stories of the space are deleted
   (``memtx_tx_story_full_unlink_on_space_delete()``, then
   ``memtx_tx_story_delete()``).
4. The savepoints of the aborted statements over the space are cleared, so
   their rollback does not touch the old space, and ``index->read_gaps`` is
   emptied.

Rollback of a statement whose stories were removed by DDL must not look for
them. The DDL transaction itself and transactions prepared before the DDL are
rolled back physically from ``stmt->engine_savepoint`` by
``memtx_tx_history_rollback_empty_stmt()``; the transactions aborted by the
DDL are already handled, and their savepoints are cleared.

The design is deliberately simple: every replace in the space cache aborts
the concurrent transactions that touched the space and deletes the stories of
the old schema, so DDL commit itself has nothing left to do.

.. _memtx-tx-snapshot-cleaner:

Snapshot cleaner
----------------

An index read view can be read in another thread, where there are no tuple
formats and the history cannot be walked. This is what the snapshot writer
does, and a user read view uses the same path. For every index read view the
engine builds a ``struct memtx_tx_snapshot_cleaner``: a hash from a dirty
index entry to the entry that is visible in that view.

``memtx_tx_snapshot_cleaner_create()`` walks ``space->memtx_stories``,
materializes the missing links (``memtx_tx_story_add_index_links()``) and
records every link that is physically in the index (``link->in_index !=
NULL``). The map is used by ``memtx_tx_snapshot_clarify()``: an entry that is
not in the map is clean and is returned as is, a mapped entry is replaced by
its visible version.

The hash key is the tuple, plus the multikey position for a multikey index;
it is not the key value. In a functional index the key stored in the link and
the key stored in the index may be different tuples, and equal keys of some
types are encoded differently, so the key value cannot be used as the hash key.

For a multikey index, the same key may occur at several positions of a tuple.
The index stores one entry for that key, but the thread that reads the view
cannot compare keys to know which of those positions the index used. The
cleaner therefore gets a record for every position with that key; all these
records refer to the same in-index entry and give the same answer. The record
for the position used by the transaction history is the original; the others
are marked ``is_duplicate``. These are alternate lookup keys for the same
in-index entry, not extra entries: without them, a lookup at another equal
position would miss the entry.

..  code:: lua

    local tuple = {id = 1, tags = {'a', 'b', 'a'}}
    -- Multikey index on tags: one in-index entry for 'a'.
    -- In the array, 'a' is at positions 1 and 3. The history may know the
    -- entry at position 1; the index may store it at position 3. The cleaner:
    --   (tuple, 1) -> visible version        -- original
    --   (tuple, 3) -> same visible version   -- alternate key, is_duplicate

The invisible-count helper behind ``offset`` and ``count``
(``memtx_tx_snapshot_invisible_count_matching_until()``) skips the
duplicates, so it counts the logical index entry once, not once per equal-key
position.

Functional keys are referenced with ``tuple_ref()`` and live until the cleaner
is destroyed: the story may be collected by GC while the read view is still
alive, but the key must outlive it.

The cleaner is also built with MVCC off, for a yielding DDL
(``space->alter_stmts``): an uncommitted DDL entry is hidden entirely, so it
does not get into the snapshot.

Transaction manager state
-------------------------

The manager state lives in one global object: ``struct tx_manager``
in ``memtx_tx.c``, a singleton called ``txm``. It holds:

- ``history``: a hash from a tuple to its story, the way the manager finds a
  story by a tuple;
- ``all_stories``: the list of all the stories, which the GC walks with the
  cursor ``traverse_all_stories``;
- ``read_view_txs``: the transactions that are in a read view, ordered by
  ``rv_psn``, so that the head of the list has the oldest one;
- ``point_holes``: a hash of point lookups that found nothing;
- ``story_link_storage``: a hash of the multikey and functional links created
  lazily for dirty tuples; a story alone does not identify such a link, while
  a regular link is resolved from the story directly;
- mempools for the stories (one per index count), the links, the point holes
  and each kind of gap item;
- statistics and the number of GC steps still to do (``must_do_gc_steps``).

Stories are linked into their space as well, through ``space->memtx_stories``.
DDL walks this list to abort the readers of the space and then to destroy the
stories (see :ref:`memtx-tx-ddl`), and the snapshot cleaner walks it to build
the map of dirty entries (see :ref:`memtx-tx-snapshot-cleaner`).

The manager keeps no list of all transactions. On the hot paths it reaches a
transaction through the objects that reference it: a reader in a story, a
gap item, a point hole, or its place in ``read_view_txs``.
There is, however, a global ``txns`` list (``src/box/txn.h``, owned by
``txn.c``) that the manager walks for whole-database passes: statistics
(``memtx_tx_statistics_collect()``), DDL (``memtx_tx_invalidate_space()``)
and teardown (``memtx_tx_manager_free()``).
