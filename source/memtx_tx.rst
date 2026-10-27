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
tuple, and there's a small wrapper ``memtx_tx_tuple_clarify``. Statements
that write use the ``_rw`` variants of both functions: they always see
prepared changes of other transactions, no matter what the isolation level
is.

The reason is that a prepared transaction has already written its changes to
the WAL, and from that moment it must be able to commit: nobody can abort it
anymore. So a statement that is going to write must see such changes at once.
If it ignored them, it would build its change on top of a state that is about
to become permanent, and the conflict would be found too late, when the
prepared transaction can no longer be rolled back. A statement that only reads
is allowed to ignore them: when the prepared transaction commits, the reader
is simply moved into a read view.

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
   store in the ``{2}`` element the information that for TX1 there was no
   element matching ``>= 1`` before ``{2}``.
2. TX2 concurrently inserts ``{1}``. It sees in its successor (which is
   ``{2}``) that TX1 requested tuples from the index and hadn't found tuples
   matching ``>= 1`` prior to ``{2}``. But we have just inserted ``{1}`` and
   it matches the key, so we have a conflict with TX1 here.

Just like that we have found a conflict of TX2 with TX1 and can handle it. The
good thing is that whether TX1 also requested data from other places in the
index does not affect this specific conflict: it's found in-place.

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
key, one per functional key. Excluded entries are not physically in the index,
so they never get a link.

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
   not being in the index), or, in a secondary index, the newer story is still
   in progress and may be rolled back.

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
chains the stories of one statement, ``next_del_stmt`` chains the statements
that deleted one story, and the first of them is ``story->del_stmt``. One
object sits on both lists at once, so dropping a deletion means unlinking it
twice, which is what ``memtx_tx_story_unlink_deleted_by()`` does; the opposite
operation is ``memtx_tx_story_link_deleted_by()``.

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

Gap items
---------

The gap items are directly or indirectly created on various operations on the
index. The directly created ones are: ``GAP_NEARBY``, ``GAP_FULL_SCAN`` and
``GAP_COUNT``. The ``GAP_INPLACE`` is either created lazily after an index
calls ``memtx_tx_track_point`` or when a conflict is detected with
``GAP_NEARBY`` (both cases are described below).

**GAP_INPLACE**

This gap item is an object that informs about the fact that some transaction
has read by a key matching this story and has found nothing. That means that
the story author conflicts with it.

This item is created in a number of cases.

1. The first case is an explicit call of the ``memtx_tx_track_point`` function.
   In this case the TX manager saves the fact that a transaction has found
   nothing equal to a full key in a structure called "point holes" (see
   :ref:`memtx-tx-point-holes`).
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
being visible. It cannot be deleted right away, though: other transactions may
have read it, and their read trackers live in it.

``memtx_tx_history_rollback_added_story()`` first sinks the story to the end of
every chain it belongs to, in every index (``memtx_tx_story_link_reorder()``),
so that the versions above it become the ones visible to the readers. The
story itself is not deleted yet: it keeps its readers until the GC removes it.

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
  indexes (``memtx_tx_handle_dups_and_gaps_on_rollback()``): the old version
  may now duplicate a newer one in a secondary index, and a transaction that
  found nothing where the new version had appeared is aborted. Both kinds of
  conflict are found by walking the chain up from the old version.

Finally the statement is unlinked from the story it added
(``memtx_tx_story_unlink_added_by()``) and from the story it deleted
(``memtx_tx_story_unlink_deleted_by()``), and the story is marked as deleted
long ago: its ``del_psn`` becomes ``MEMTX_TX_ROLLBACKED_PSN``, which is 1, a
value below ``TXN_MIN_PSN`` and thus below any real psn. No reader can see the
story anymore.

Transaction manager state
-------------------------

Everything described above lives in one global object: ``struct tx_manager``
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
stories, and the snapshot cleaner walks it to build the map of dirty entries.

There is no global list of transactions. The manager reaches a transaction only
through the objects that transaction registered: a reader in a story, a gap
item, a point hole, or its place in ``read_view_txs``.
