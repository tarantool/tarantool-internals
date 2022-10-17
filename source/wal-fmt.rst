.. vim: ts=4 sw=4 et

WAL file binary format
======================

General overview
----------------

The WAL file starts with ``meta`` information block following by ``xrow`` entries.

 +--------------+
 |  meta block  |
 +--------------+
 |  xrows block |
 +--------------+
 |  xrows block |
 +--------------+

Meta information block
----------------------

The ``meta`` block ends up by ``\n\n`` marker. Each entry inside the block
is ``\n`` separated records. The block is started with obligatory ``signature``,
``version`` followed by ``key:value`` array.

 +-------------+
 |  signature  |
 +-------------+
 |  version    |
 +-------------+
 |  key: value |
 +-------------+

 The ``signature`` either ``XLOG`` for regular WAL files or ``SNAP`` for
 snapshots. For example an empty WAL file might look like

 +-------------------------------------------------------+
 | ``XLOG\n``                                            |
 +-------------------------------------------------------+
 |  ``0.13\n``                                           |
 +-------------------------------------------------------+
 | ``Version: 2.5.0-136-gef86e3c99\n``                   |
 +-------------------------------------------------------+
 | ``Instance: 123a579d-4994-4e7c-a52f-6b576a8988d7\n``  |
 +-------------------------------------------------------+
 | ``VClock: {1: 8}\n``                                  |
 +-------------------------------------------------------+
 | ``PrevVClock: {}\n``                                  |
 +-------------------------------------------------------+
 | ``\n``                                                |
 +-------------------------------------------------------+

 Note the double ``\n\n`` formed by last entry and ``PrevVClock`` entry.
 This represents the end of meta information block.

Data blocks (xrows)
-------------------

The meta block carries only service information about content of the
WAL file. The real data appended into the WAL file in xrows records.
Structure of each record is the following

+--------------+
| fixed header |
+--------------+
| xrows header |
+--------------+
|  xrows data  |
+--------------+
| xrows header |
+--------------+
|  xrows data  |
+--------------+
|     ...      |
+--------------+

The ``fixed header`` defined as

.. code-block:: c

    /* box/xlog.c */
    struct xlog_fixheader {
        log_magic_t magic;
        uint32_t    crc32p;
        uint32_t    crc32c;
        uint32_t    len;
        // padding to 19 bytes
    };

``magic`` is one of the following constants

+----------------+-------------------+
| ``0xd5ba0bab`` | uncompressed rows |
+----------------+-------------------+
| ``0xd5ba0bba`` | compressed rows   |
+----------------+-------------------+
| ``0xd510aded`` | end of file       |
+----------------+-------------------+

The ``xlog_fixheader`` should have length of 19 bytes on disk so right
after the structure the padding is pushed. ``magic`` points how xrows
are kept - either they are compressed (with zstd compression library)
or not.

Aside from this the ``magic`` may have end of file representing that there
is no more data. Thus when read ``xlog_fixheader`` structure from disk
we need to read 4 bytes first and make sure it is not EOF value.

The ``len`` value stores the number of bytes occupied by xrow headers
with data. If xrows are compressed we should read ``len`` bytes and
decompress them.

Decompressed stream consists of xrow header plus xrow data pairs.
Header represented as

.. code-block:: c

    /* box/xrow.h */
    struct xrow_header {
        uint32_t        type;
        uint32_t        replica_id;
        uint32_t        group_id;
        uint64_t        sync;
        int64_t         lsn;
        double          tm;
        int64_t         tsn;
        uint64_t        stream_id;
        uint8_t         flags;
        int             bodycnt;
        uint32_t        schema_version;
        struct iovec    body[XROW_BODY_IOVMAX];
    };

Each ``xrow_header`` describes the ``body`` data, ie the requests to be
executed (like insert, update and etc). Note that ``xlog_fixheader::len``
may cover not one ``xrow_header`` but a series of headers and xrow requests.

Tarantool provides a ``tt`` tool, which can also be userd to show the content
of files in a human readable form.

.. code-block:: shell

    $> tt cat --show-system 00000000000000000000.xlog

    • Result of cat: the file "00000000000000000000.xlog" is processed below •
    ---
    HEADER:
      lsn: 1
      replica_id: 1
      type: UPDATE
      timestamp: 1665049874.9756
    BODY:
      space_id: 272
      index_base: 1
      key: ['max_id']
      tuple: [['+', 2, 1]]
    ---
    HEADER:
      lsn: 2
      replica_id: 1
      type: INSERT
      timestamp: 1665049874.9766
    BODY:
      space_id: 280
      tuple: [512, 1, 'test', 'memtx', 0, {}, []]
    ---
    HEADER:
      lsn: 3
      replica_id: 1
      type: INSERT
      timestamp: 1665049885.4396
    BODY:
      space_id: 288
      tuple: [512, 0, 'primary', 'tree', {'unique': true}, [[0, 'unsigned']]]
    ---
    HEADER:
      lsn: 4
      replica_id: 1
      type: INSERT
      timestamp: 1665049934.8938
    BODY:
      space_id: 512
      tuple: [1, 'Mail.ru Group']
    ---
    HEADER:
      lsn: 5
      replica_id: 1
      type: REPLACE
      timestamp: 1665049945.4349
    BODY:
      space_id: 512
      tuple: [1, 'VK']
    ...


Another example is more detailed example for same file

.. code-block:: shell

    $ /ttdump examples/00000000000000000008.snap

    meta: Instance            : 'd738afea-3764-4d12-9f41-eec2c7a36790'
    meta: VClock              : '{}'
    meta: Version             : '2.11.0-entrypoint-546-g302d91cf8'
    fixed header
    -------
      magic 0xab0bbad5 crc32p 0 crc32c 0xd032f6b5 len 40
    -------
    xrow header
    -------
      type 0x4 (UPDATE) replica_id 0x1 group_id 0 sync 0 lsn 1 tm 1.665e+09 tsn 1 is_commit 1 bodycnt 1 schema_version 0x431760
        iov: len 23
    -------
    key: 0x10 'space id' value: 272
    key: 0x15 'index base' value: 1
    key: 0x20 'key' value: {max_id}
    key: 0x21 'tuple' value: {{+, 2, 1}}
    -------
    fixed header
    -------
      magic 0xab0bbad5 crc32p 0 crc32c 0xf3012529 len 42
    -------
    xrow header
    -------
      type 0x2 (INSERT) replica_id 0x1 group_id 0 sync 0 lsn 2 tm 1.665e+09 tsn 2 is_commit 1 bodycnt 1 schema_version 0x431760
        iov: len 25
    -------
    key: 0x10 'space id' value: 280
    key: 0x21 'tuple' value: {512, 1, test, memtx, 0, {}, {}}
    -------
    fixed header
    -------
      magic 0xab0bbad5 crc32p 0 crc32c 0x94627a85 len 62
    -------
    xrow header
    -------
      type 0x2 (INSERT) replica_id 0x1 group_id 0 sync 0 lsn 3 tm 1.665e+09 tsn 3 is_commit 1 bodycnt 1 schema_version 0x431760
        iov: len 45
    -------
    key: 0x10 'space id' value: 288
    key: 0x21 'tuple' value: {512, 0, primary, tree, {unique: true}, {{0, unsigned}}}
    -------
    fixed header
    -------
      magic 0xab0bbad5 crc32p 0 crc32c 0x5051efc8 len 39
    -------
    xrow header
    -------
      type 0x2 (INSERT) replica_id 0x1 group_id 0 sync 0 lsn 4 tm 1.665e+09 tsn 4 is_commit 1 bodycnt 1 schema_version 0x431760
        iov: len 22
    -------
    key: 0x10 'space id' value: 512
    key: 0x21 'tuple' value: {1, Mail.ru Group}
    -------
    fixed header
    -------
      magic 0xab0bbad5 crc32p 0 crc32c 0x25db870 len 28
    -------
    xrow header
    -------
      type 0x3 (REPLACE) replica_id 0x1 group_id 0 sync 0 lsn 5 tm 1.665e+09 tsn 5 is_commit 1 bodycnt 1 schema_version 0x431760
        iov: len 11
    -------
    key: 0x10 'space id' value: 512
    key: 0x21 'tuple' value: {1, VK}
