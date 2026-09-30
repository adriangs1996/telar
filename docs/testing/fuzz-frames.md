# Frame, cell run and text metadata fuzzing

Three native Zig fuzz targets cover the three layers of a pane frame: the frame
body, the cell runs inside its spans, and the text metadata beside them. They
use `std.testing.fuzz` and `std.testing.Smith` from Zig 0.16.0 and need no
other tools. Every input is a synthetic buffer in memory: no runtime, window,
socket, PTY or file is involved.

This is local robustness QA for our own codecs. It is not a security audit.

## Wiring

`build/fuzz_frames.zig` registers the steps, but nothing calls it yet. The
steps exist only after the registry is connected in `build/tests.zig`:

```sh
git apply /tmp/dispatch-claude/robustness-fuzz-frames-integration.patch
```

The patch adds one import and one call, `fuzz_frames.add(b, app.modules);`,
next to the handshake target. It will be reviewed together with the other
fuzz sessions before it is committed.

## Steps

| Step | Executable | Root |
| --- | --- | --- |
| `test-fuzz-frames` | all three | |
| `test-fuzz-frames-body` | `frame-body-fuzz` | `src/core/frame_fuzz_root.zig`, which imports `src/core/schema/frame_fuzz_test.zig` |
| `test-fuzz-frames-cells` | `cell-run-fuzz` | `lib/cellcodec/cell_run_fuzz_test.zig` |
| `test-fuzz-frames-metadata` | `text-metadata-fuzz` | `src/core/text_metadata/metadata_fuzz_test.zig` |

Without `--fuzz`, a step runs its unit tests and replays each seed corpus. With
`--fuzz=<limit>` it fuzzes every fuzz test in the executable, up to `limit`
runs each. Run campaigns through the per-target steps so that one executable
fuzzes at a time:

```sh
zig build test-fuzz-frames -Dgui=false -j1
zig build test-fuzz-frames-body -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-frames-cells -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-frames-metadata -Dgui=false -j1 --fuzz=10K
```

No suite and no coverage build imports these roots. As in the handshake
target, each executable is built with LLVM and without error return traces,
and runtime safety stays on.

The frame body root sits in `src/core/` because `frame_support.zig` imports
`../text_metadata`, and a module cannot import above the directory of its root
file. Because the root is in `src/core/`, the frame executable also runs the
unit tests of the schema files it reaches, such as `frame_support.zig`.

The three targets bind `unicode` to `lib/unicode/fake.zig` through their own
`Libraries.create`, which is how the portability checks build it. Built with
`--fuzz`, the real provider's C++ width tables call
`__sanitizer_cov_trace_cmp*` hooks, and Zig's fuzzer does not define them, so
the link fails. None of these codecs measures a grapheme.

## Contracts and oracles

### Frame body (`frame_fuzz_test.zig`)

`decodeBody` validates the header, the metadata and the span layout. It does
not decode cells: `cellcodec.CellReader` checks them when a consumer reads
them. A frame that is structurally accepted can therefore still hold cells
that a consumer rejects. The targets allow that case.

- **`fuzz frame body decoding`** decodes arbitrary bytes, up to 4096 bytes. A
  rejection is a normal outcome. An accepted body must keep every structural
  promise:
  - valid ids, geometry, cursor and scroll;
  - no more than `max_span_count` spans and `max_body_size` bytes;
  - metadata that is borrowed from the body and has one flag per row, with
    every link and run lookup staying inside its bytes;
  - exactly `span_count` ordered, non-empty spans inside the grid, whose
    headers and cells fill `encoded_spans` exactly;
  - for a snapshot, one span covering the whole grid.

  Each span's cells are then read. A span may reject its cells. When every
  span reads, each cell is valid and each run measures no more than its
  encoded length. The decoded values are then encoded again. The result must
  equal the input byte for byte when the cells were written the way `encode`
  writes them. Otherwise it must be shorter and decode to the same values.
  `decodeBody` reads only the body, so bytes after it are ignored.
- **`fuzz generated frames`** builds valid snapshots and patches of up to
  16x8 cells, with every header field drawn from its whole range, legal
  metadata or none, and up to 8 spans. The encoded length must equal the sum
  of the header, the metadata and `encodedCellsSize` of every span. The body
  must decode, consuming exactly what was written, to the same header,
  metadata, spans and cells. A null snapshot metadata decodes as an empty
  complete replacement, and a null patch metadata decodes as unchanged. Then
  a fault is drawn: none with weight 8, each of 21 faults with weight 1. A
  fault that does not fit the frame (a span fault without spans, a snapshot
  fault on a patch) is skipped. Otherwise one rule is broken in the bytes,
  and in the `Frame` value when it can hold the fault. Decoding the broken bytes, and encoding the
  broken value, must then fail with that rule's error. The faults cover
  truncation, zero pane and frame ids, a stale base, the cursor (hidden off
  the origin, visible outside the screen, on either axis), each enum and
  boolean byte, the scroll, too many spans, oversized or missing snapshot
  metadata, empty, overlapping and off-screen spans, a partial snapshot, and
  a span shorter than its cell count.
- **Directed maxima:**
  - the largest screen exactly (`3 x 43453 = max_cell_count`), with one more
    row refused;
  - a body of exactly `max_body_size` that is structurally accepted while its
    first cell is rejected by `CellReader`, with one more byte giving
    `FrameTooLarge`;
  - `max_span_count` spans decoding, with one more refused on both sides.

Seeds (12): a snapshot that sets every header field, a linked snapshot, a
patch with metadata, an empty patch, a patch whose cells are unreadable
(structurally accepted), and the errors truncation, missing snapshot metadata,
overlapping, empty and off-screen spans, oversized metadata and a cursor
outside the screen. A test checks each seed's outcome and the Smith encoding
of its corpus entry.

### Cell runs (`cell_run_fuzz_test.zig`)

- **`fuzz cell run decoding`** reads a fuzzed payload of up to 64 cells
  (1984 bytes) with a fuzzed promised count, alongside a reference reader
  written from the format's description. At every step, `CellReader` must
  return the same canonical cell (default bytes after the text, zeroed unused
  color channels), the same end or the same error, in the same order. A run
  read to its end must encode again to cells that read back the same. When no
  header repeated an unchanged style, the new encoding must be exactly the
  payload; when one did, it must be strictly shorter.
- **`fuzz generated cell runs`** generates up to 64 valid cells with inherited
  and changed styles, every color kind and every legal flag. The bytes after
  the text and the unused color channels hold arbitrary values, and they are
  never compared. The same run is encoded several ways after a prefix of up
  to 12 bytes:
  - through the reserved path;
  - through the checked path in a buffer of exactly its size;
  - with a limit of exactly its size.

  All three must write the same bytes, and their count must equal
  `encodedCellsSize`. That count must also equal a reference size, including
  when the run is appended after another style. One byte less of buffer gives
  `BufferTooSmall`, and one byte less of limit gives `LimitExceeded` without
  passing the limit. Every encoding must read back as the cells' canonical
  form. A non-empty run carries one invalid cell with weight 5 against 4:
  text over 16 bytes, width over 2, text without width, width without text,
  or reserved flag bits. Both
  paths must then fail with `InvalidCell` or `InvalidStyle`.

Seeds (19): a default cell, an inherited style, a changed style, a wide glyph
and its spacer, 16 bytes of text, a repeated unchanged style, zero promised
cells, and each rejection (a first cell without a style, text too long,
width 3, zero width with text, width without text, reserved flags, underline
6, color kind 3, truncated style, truncated text, a missing promised cell,
trailing bytes).

### Text metadata (`metadata_fuzz_test.zig`)

- **`fuzz text metadata decoding`** decodes a fuzzed payload of up to 8192
  bytes for a fuzzed screen of 0 to 64 columns and 0 to 16 rows, alongside a
  reference validator. A rejection must be the error the validator names, in
  the order the format is read. An accepted view must pass these checks:
  - it borrows exactly the payload;
  - every `link` falls inside the URI bytes, in order;
  - `runs` yields each run;
  - `at` agrees with a walk over the runs for every cell and one past the
    screen.

  Rebuilding the view through `Builder` must give back exactly the payload.
  `View.trusted` is reached only through `View.decode` or `Builder.finish`.
- **`fuzz generated text metadata`** builds legal replacements: row flags
  (wide padding only on wrapped rows at least 2 columns wide), up to 8 links
  of up to 64 arbitrary bytes, and up to 32 sorted, row-local runs. It also
  sometimes attempts an empty or oversized link, which must be refused
  without changing the builder. The result must decode to the rows, URIs and
  runs it was built from, or to the rows alone when omitted. Every strict
  prefix gives `Truncated`, one more byte gives `TrailingBytes`, and a
  different row count gives `InvalidTextMetadata`.

Seeds (30): an empty complete replacement, the linked fixture, an omitted
replacement with wide padding, exactly `max_links` links, one URI of exactly
`max_uri_bytes`, and each rejection. The rejections include:

- truncation and trailing bytes;
- an unknown status, a wrong row count, or links in an omitted replacement;
- one more than the link, run, URI-total and URI-length limits;
- reserved row bits, or wide padding without wrap or on one column;
- URI gaps, zero-length links and unclaimed URI bytes;
- empty, overlapping, unordered, row-crossing, off-screen and overflowing
  runs;
- an unknown link, and zero columns.

## Bounds

Every loop has an explicit bound. The constants at the top of each file name
the payload sizes, the screen sizes and the counts of links, runs, spans and
cells. The largest cases do not come from fuzzing: they are the directed tests
and seeds above, and the maxima that `src/core/text_metadata/tests.zig`
already covers.

## Reading results

- The report prints the name of the executable's first fuzz test, but its
  runs, unique runs and coverage belong to the whole executable, runner
  included. Coverage is global program counters, not coverage of these
  codecs. With `--fuzz=10K` and two fuzz tests, an executable reports about
  20K runs.
- Each fuzz test keeps its corpus in `<cache>/f/<hex of Wyhash(test name)>/`.
  A new directory for a test shows that it ran with fresh inputs.
- A broken property panics, so the fuzzer keeps the input. Zig 0.16.0 still
  exits `zig build` with status 0 after a crash. Look for `terminated with
  signal` in the output instead.
- The reported `<cache>/f/crash` can be empty or truncated: on this host it
  held 0 bytes of a 35-byte input and 512 bytes of a 964-byte one. The input
  the crashed instance was running stays in `<cache>/f/in<N>`, after a
  20-byte header (`pc_digest: u64, instance_id: u32, test_i: u32, len: u32`).
  Copy `len` bytes from offset 20.

## Reproducing a failure

1. Take the input from `f/in<N>` as described above. Its `test_i` field names
   the failing test.
2. Save it next to the target, keeping its name, and add
   `@embedFile("<name>")` to that `std.testing.fuzz` call's `.corpus`. The
   generated tests take a `.corpus` field too.
3. `zig build test-fuzz-frames-<target> -Dgui=false -j1` now replays it
   without fuzzing.

Do not fix the codec or relax the oracle in the same change. Report the input
with a separate regression test first.

## Known edge

`CellReader.init(bytes, 0)` returns null without reading `bytes`, so trailing
bytes after zero promised cells are not reported. `decodeBody` rejects
empty spans before a reader exists, so no frame can reach this case. The
cells seed "zero promised cells" pins the current behavior until someone
decides whether a zero count should still check for trailing bytes.
