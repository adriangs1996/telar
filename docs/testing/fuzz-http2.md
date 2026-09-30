# HTTP/2 fuzz targets

Two native Zig fuzz targets cover telar's own HTTP/2 code. They run on
synthetic frames in memory, with no sockets, TLS, servers or captured traffic.

| Target | Root | Step |
| --- | --- | --- |
| Frame `Reader` (`lib/h2frames/Reader.zig`) | `lib/h2frames/reader_fuzz_test.zig` | `test-fuzz-http2-reader` |
| Header `Observer` (`lib/httprelay/http2/Observer.zig`) | `lib/httprelay/http2/observer_fuzz_test.zig` | `test-fuzz-http2-observer` |

`test-fuzz-http2` runs the `h2frames` and `httprelay` library tests and both
roots. The registration lives in `build/fuzz_http2.zig`.

## Pending wiring

`build/tests.zig` does not call `fuzz_http2.add` yet, so none of these steps
exist on a plain checkout. Two lines connect them:

```zig
const fuzz_http2 = @import("fuzz_http2.zig");
// ... inside `add`, next to the handshake step:
fuzz_http2.add(b, app);
```

The patch that was used to test the steps is kept outside the repository at
`/tmp/dispatch-claude/robustness-fuzz-http2-integration.patch`. It will be
merged together with the other fuzz sessions' wiring.

## How each root is built

Each root is its own test module. It imports its library as a module
(`h2frames` or `httprelay`) from `app.modules.libraries`, so nghttp2 and libc
come from the existing graph. Following `handshake_fuzz_test.zig`, the fuzz
artifact is built with LLVM and without error return traces, and runtime
safety stays on. No ordinary suite and no `-ffuzz` coverage build imports
these roots.

`Observer` is private to `httprelay`. A root in `lib/httprelay/http2/` can't
import it directly, because `Observer.zig` imports `../RouteMatch.zig` and Zig
rejects imports outside the module root. So the observer target calls the
public `http2.relay` with a session that lives in memory. The relay makes the
nghttp2 memory hooks with `header_memory.of(&gpa)`, starts one `Observer`,
feeds it what the session reads and always deinits it. The session's
allocator, the hooks and the sink all outlive the observer.

## Reader

**Input.** One wire of at most `max_wire_bytes` (256), a rejection plan and
a partition of up to `max_partition_chunks` (8) chunk lengths of 1 to
`max_chunk_bytes` (64). The plan says which callback the receiver refuses:
none, the begin of frame N, the payload fragment that covers wire byte N, or
the finish of frame N.

**Feedings.** Every run feeds the wire whole, split in two at every
position, one byte at a time and in the generated partition.

**Oracles.** An independent walk of the wire (`modelTrace`) gives the frames
`Reader` must report for any prefix. The receiver records what it saw and
checks each callback as it happens:

- a begin arrives only after a whole header and never inside a frame;
- a payload fragment is non-empty, lies inside the chunk being fed, starts at
  `payload_offset`, matches the wire bytes at that position and never passes
  the declared length;
- a finish comes after exactly `length` payload bytes;
- nothing is called after a refusal.

After every accepted chunk, the recorded frames (type, flags, stream id with
the reserved bit cleared, length, payload start, bytes delivered, finished)
must equal the model of the prefix fed so far. The reader's `header_len`,
`payload_len`, `payload_offset` and `payload_left` must match the partial
header or payload the model left pending. Payload is compared as a total per
frame, because the number of payload callbacks changes with chunking.

A refusal must make `feed` return false on the chunk that holds the trigger
byte, and on no earlier chunk. The trace must end at the refused callback. A
refused payload keeps its whole fragment, which ends where the chunk or the
frame ends. `feed` promises nothing after it returns false, so the run stops
there.

**Seeds.** 20 seeds: an empty wire, partial headers, complete and truncated
frames, two empty frames, a 16 MiB declared length with 3 bytes of payload,
a length that needs its middle byte, a padded frame, a set reserved bit, an
unknown type with every flag set, and three concatenated frames with and
without every kind of rejection.

## Observer

**Input.** A direction, an allocation index to fail (0 means none, up to
`max_fail_index` 96), a partition, then up to `max_frame_ops` (12) frame
operations:

- `headers`, `push_promise`: a header block of up to `max_block_fields` (6)
  fields. It may start with a dynamic table size update (0, 64, 256 or 4096)
  and may carry padding (up to `max_padding` 8), a PRIORITY prefix, and a
  split over up to `max_fragments` (4) frames. Fields use each RFC 7541
  representation except Huffman: indexed static, indexed dynamic, literal
  with incremental indexing, without indexing and never indexed, with a new
  or indexed name. Values come from a table or are up to `max_value_bytes`
  (24) of fuzzed printable text.
- `data` with padding and up to `max_body_bytes` (48) of body, `rst_stream`,
  `goaway`, `settings`.
- `raw_block`: a HEADERS frame around up to 48 fuzzed HPACK bytes.
- `raw`: up to 48 bytes appended as they are.

A header operation may break the protocol in one named way (`Breakage`):
stream id zero, a pad length past the payload, a PING between HEADERS and
CONTINUATION, a CONTINUATION on another stream, a missing END_HEADERS, index
zero as the first field, or the block's last byte cut off.

The generator keeps a model of the inflater's dynamic table. It starts at
nghttp2's 4096 bytes, evicts oldest first and costs name, value and 32 bytes
per entry. The model knows which field every index names. PUSH_PROMISE
blocks change the table but emit no fields.

**Relays.** Each run relays the wire whole, one byte at a time and in the
generated partition, each time with a fresh observer on
`std.testing.allocator`. A last relay uses a `FailingAllocator` when the fail
index is non-zero.

**Normalization.** The sink copies each event into a bounded trace
(`max_observations` 256 events, `max_observed_bytes` 8 KiB of names, values
and bodies). It joins consecutive body fragments of one stream and drops a
`response_activity` that continues the same stream's body, because chunking
splits DATA into more fragments and more activity events. Past its bounds the
trace records that it overflowed and stops, and that cut does not depend on
chunking.

**Oracles.**

- The relay forwards every byte unchanged and half-closes.
- Whole, bytewise and partitioned relays give the same normalized trace and
  the same `decode_failed`.
- A valid wire, with no breakage and no raw bytes, never fails. It emits
  exactly the generated fields, in order, on their streams, which shows every
  block went through `decodeBlock` and nghttp2's inflater.
- A breakage the observer must fail on sets `decode_failed`.
- Unless raw bytes are involved, the decoded fields are a prefix of the
  generated ones. A failure may stop decoding but may not change a field it
  already emitted.
- Allocation failure. When the failing allocator did fail, the observer must
  report `decode_failed`, the decoded fields must be a prefix of the
  unfailed run's, and allocated bytes must equal freed bytes. When it did not
  fail, the trace must equal the unfailed one. `std.testing.allocator`
  checks for leaks in every run.

An observer that failed keeps reporting DATA and lifecycle events, as the
code does. The oracles do not model lifecycle events, only compare them
across chunkings.

**Seeds.** 18 seeds: empty wires in both directions, a watched POST with a
body, dynamic table references across blocks with table size updates, a
padded and prioritized response split over three frames with SSE bodies,
PUSH_PROMISE feeding the dynamic table, RST_STREAM and GOAWAY, HEADERS whose
first frame is only padding, a cut that drops a whole indexed field (found by
fuzzing, see below), one seed per breakage, RFC 7541 C.4.1 (Huffman) as a raw
block, the relay tests' `\x83\x04\x0c/v1/messages` block, and raw bytes that
leave a frame incomplete.

**Deterministic tests** in the root, run by `test-fuzz-http2` without
`--fuzz`:

- every seed reaches its declared outcome and holds every property;
- valid seeds emit every generated field;
- the watched request seed starts a watched request and finishes it;
- the Huffman seed decodes to the four RFC 7541 C.4.1 fields;
- every seed keeps its trace when split at every position;
- `checkAllAllocationFailures` fails every allocation index of each valid
  seed. A run that lost an allocation must report `decode_failed`, which the
  test turns into `error.OutOfMemory`, and must free everything.

## Commands

```sh
zig build test-fuzz-http2 -Dgui=false -j1              # tests and seed replay
zig build test-fuzz-http2-reader -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-http2-observer -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-http2 -Dgui=false -j1 --fuzz=10K   # both targets
```

Run one campaign at a time, and always give `--fuzz` a limit.

## Reading a failure

Zig 0.16.0's `zig build --fuzz` exits 0 even when a target aborts, so read the
output for `terminated with signal ABRT; input saved to '<cache>/f/crash'`.

On this host (macOS, aarch64) the `crash` file came out empty every time. The
failing input stays in `<cache>/f/in<N>` behind a 20-byte header (u64 pc
digest, u32 instance, u32 test index, u32 length, little-endian). Check that
the digest matches the one in the fuzzing report and take the next `length`
bytes. Those bytes are in `std.testing.Smith` input form. To replay them,
embed the file in a test that calls `expectFuzzedFeeding` or
`expectFuzzedObservation`, or add it to the corpus.

A found failure that is real stays as a seed with a comment.
Fuzzing found one oracle bug while this was written. Cutting the last byte of
a block whose last field is a one-byte index leaves a valid, shorter block,
and decoding goes on. The oracle now models that case, and the seed "a cut
that drops a whole indexed field" pins it.

## Limits

- nghttp2 is a separate C library artifact built in ReleaseFast. `--fuzz`
  rebuilds only the test artifact with `-ffuzz` (`rebuildInFuzzMode` in
  `std/Build/Fuzz.zig`), so the inflater is not instrumented and gives the
  fuzzer no coverage feedback. The fuzzer reaches it only through the Zig
  code around it. The coverage figure in the report counts the whole
  test executable, including the test runner and this harness. It is not
  Reader or Observer coverage.
- A campaign of 10K runs finds shallow faults. Passing one doesn't mean the
  code has no errors.
- The generator does not produce Huffman literals. Only the C.4.1 seed and
  fuzzed raw blocks reach Huffman decoding.
- HTTP/1, decompression, TLS and the live relay are out of scope.
