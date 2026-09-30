# Fuzzing client message decoding

`decodeClient` turns every payload a client sends the runtime after the
handshake into a `ClientMessage`. This target fuzzes it with Zig's built-in
fuzzer (`std.testing.fuzz`), from its own test root
[`src/core/schema/messages/client_fuzz_test.zig`](../../src/core/schema/messages/client_fuzz_test.zig),
registered by [`build/fuzz_ipc_client.zig`](../../build/fuzz_ipc_client.zig)
as the step `test-fuzz-ipc-client`.

It is QA on telar's own decoder. Every input is a synthetic buffer in memory.
No socket, runtime, child process or user data is involved, and a decoded
message is never executed.

## Commands

Replay the corpus and run the deterministic tests, without fuzzing:

```sh
zig build test-fuzz-ipc-client -Dgui=false -j1
```

Fuzz for a bounded number of runs; the limit takes Zig's `K`, `M` and `G`
suffixes:

```sh
zig build test-fuzz-ipc-client -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-ipc-client -Dgui=false -j1 --fuzz=5M
```

On the development host (aarch64 macOS, Debug) 5M runs took 64 seconds,
build included. `--fuzz` without a limit keeps going and serves Zig's web
interface; it has not been tried here. Pass `--cache-dir <dir>` to keep the
fuzzer's corpus and inputs apart from another checkout's.

## What the properties check

The decoder decides what it accepts. The properties do not reimplement it;
they check what any answer owes, whatever the decoder chose.

For every rejected payload:

- an empty payload is `Truncated`;
- a first byte that names no `ClientTag` is `UnknownMessage`.

For every accepted payload:

- the variant is the one its tag byte names;
- every byte slice in the decoded value, views and nested unions included,
  points inside the payload after its tag;
- the payload cut at `0`, `len / 2` and `len - 1` bytes is rejected as
  `Truncated`, and the payload with one more byte as `TrailingBytes`. Every
  client message has a fixed or length-prefixed shape, so a cut payload runs
  out of bytes before any check the whole one passed. `pane_input` is exempt,
  because its bytes run to the end of the payload;
- every iterator of a view (launch arguments and environment, import entries,
  layout tabs and their nodes) yields exactly the declared count, borrows only
  the view's encoded bytes, consumes all of them and stays within the schema's
  budgets. A layout iterator never fails, since the decoder validated every
  tree;
- a launch or import iterator may reject an item's content, which the decoder
  leaves to it, only with an error that item's own bytes justify. The test
  reads the rejected item again from where the iterator started it and
  accepts exactly these:

  | Iterator | Error | Only when |
  | --- | --- | --- |
  | arguments | `InvalidByteString` | the argument is empty and it is the first |
  | arguments | `EmbeddedNul` | the argument holds a NUL |
  | environment | `InvalidByteString` | the name is empty |
  | environment | `EmbeddedNul` | the name or the value holds a NUL |
  | environment | `InvalidEnvironmentName` | the name holds `=` |
  | import entries | `InvalidByteString` | the command is empty |

  Any other error, `Truncated` included, fails. The table checks that a
  rejection names a real defect of the item; it does not check which error a
  decoder with several defects reports first;
- when every item passes its iterator, the production encoder accepts the
  decoded message, `decodeClient` accepts what it wrote and returns an equal
  message, and encoding that again gives the same bytes. The check is
  semantic equality plus a stable re-encoding; it does not require the
  original bytes back.

When an iterator rejects an item, the round trip is skipped for the whole
message: the encoder is not called, and no field of that message, the items
before the rejected one included, is compared after re-encoding. The variant,
borrowing, framing, the items read before the rejection and the rejection's
justification are still checked. No field is normalized to force a round
trip.

A broken property panics with the error name and the payload in hex. The
fuzzer keeps the input for any abnormal exit of the test process; the panic
adds the error and the payload to the output.

## Known divergences

Two findings of this target, in three messages, are open in production. The
decoder accepts these messages and their encoder refuses them:

| Message | Condition on the decoded message | Encoder error |
| --- | --- | --- |
| `read_history_output` | `id == 0` | `InvalidHistoryId` |
| `delete_history` | `id == 0` | `InvalidHistoryId` |
| `import_history` | `source` non-empty, within `max_import_source_bytes`, without a NUL; and at least one command holding a NUL | `EmbeddedNul` |

The first finding is history id 0. The fuzzer found it in
`read_history_output` after about 19,700 runs; `delete_history` shares the
same derived decoder, which its regression payload confirms. The second is a
NUL in an imported command, found by a directed seed: `ImportEntryIterator`
rejects an empty command but not a NUL, and `encodeImportHistory` rejects
both.

`known_divergences` lists each one as the tag, the encoder error and the
condition above, checked on the decoded message by the entry's `holds`
function. All three must match to excuse an encoder error. The same error for
any other reason still fails: an `EmbeddedNul` caused by a NUL in `source` is
not excused, which the test "an import whose source holds a NUL never counts
as the known divergence" shows, and the seed "import_history with a NUL in
source" pins the decoder's own rejection of it.

When an entry excuses a message, the round trip is skipped for that whole
message, exactly as for an iterator rejection: the other fields of that
message (the request id, and for an import the source, the base sequence and
every entry) are not compared after re-encoding. Variant, borrowing, framing
and iterator checks still run.

The test "every known divergence still holds for its payload" decodes each
minimal payload, checks its condition and expects the recorded encoder error,
so it fails once production settles an entry. Then the entry goes and its
payload joins the seeds.

The table exists so campaigns can explore past these findings: with a strict
round trip, every campaign stopped on the first one within about 20,000 runs.

## Corpus

The seeds are built at runtime with the production encoders, plus a raw
writer for payloads the encoders refuse. There are 127 of them, all with
fictitious data: 80 the decoder accepts and 47 it rejects, each with the exact
outcome the seed test checks. A seed is stored in the form
`std.testing.Smith.slice` reads, a little-endian `u32` length and the payload,
which is also the form a saved input takes.

Every one of the 60 client tags has at least one accepted seed. The function
`claimedCoverage` states that per tag and the test "the seed corpus covers the
tags it claims" derives the same answer from the corpus; its switch is
exhaustive, so a new tag does not compile until someone claims it. Reaching a
tag is not the same as covering its decoder, and this target does not measure
per-decoder coverage.

Beyond one message per tag, the seeds cover:

- every `open_pane` target, launches with 64 arguments and with 256
  environment entries, and launches whose items the iterators reject: an
  argument holding a NUL, an empty program, an environment name holding `=`,
  an empty environment name and an environment value holding a NUL, one per
  tolerated iterator error;
- `query_history` in the global, cwd and pane scopes, an import batch at 64
  entries, an import entry with an empty command, and an import whose source
  holds a NUL, which the decoder rejects;
- a layout update with 127 nodes in one tab and one with two tabs;
- `send_pane_text` without text in `raw_enter` mode and with a sender,
  `move_tab` relative to another tab, colors with and without a palette.

The 24 tags with rejection seeds cover unknown enum values and flags, zero
identities, counts one past their limit and zero, missing and extra bytes,
invalid UTF-8, control bytes, broken layout trees (a missing child, a
duplicate pane, focus outside the tree, a ratio below its bound, an active
tab not among the tabs) and the envelope: an empty payload, the lowest
unassigned tag, a gap inside the client range, a server tag and `0xff`.

`saved_inputs` lists inputs a campaign saved. It is empty now.

## Bounds

- `payload_capacity`: 4 KiB, the longest input the fuzzer builds. It holds
  every seed, including the 127-node layout and the 256-entry environment.
- `reencode_capacity`: twice that. A re-encoding longer than its payload
  fails as a property, not as a full buffer.
- Budgets past 4 KiB are deterministic tests at exactly the limit and one
  byte over: launch argument bytes (128 KiB), environment bytes (512 KiB),
  pane input (64 KiB) and one imported command (4 KiB). They build their
  payloads with the testing allocator and are not fuzz seeds, so a fuzz
  iteration never pays for them.
- The iterator and layout storage the round trip fills is sized by the
  schema's own maxima (`max_argument_count`, `max_environment_count`,
  `max_import_entries`, `max_client_layout_tabs`, `max_client_layout_nodes`)
  and lives in a static buffer, so a Debug build does not refill about 50 KiB
  of stack every iteration.

## Reproducing a failure

A failed campaign prints `decodeClient property failed: <error> for payload
<hex>` and `input saved to '<cache>/f/crash'`. `zig build` still exits 0 with
Zig 0.16.0, so read the output.

On this host Zig 0.16.0 wrote `f/crash` empty every time. The input is still
in `f/in<instance>`, after a 20-byte header whose last `u32` is its length:

```sh
python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); n=struct.unpack_from("<I",d,16)[0]; open(sys.argv[2],"wb").write(d[20:20+n])' \
  <cache>/f/in0 src/core/schema/messages/client_fuzz_<finding>.bin
```

Read it before the next campaign reuses the file. The hex payload in the
panic gives the same input without the Smith length.

Add the file to `saved_inputs` as `@embedFile("client_fuzz_<finding>.bin")`;
a plain `zig build test-fuzz-ipc-client` then replays it and fails until the
decoder or the property changes.

## How the target is built

- The root imports `telar-core` and `bytecodec` as modules and nothing else.
  No suite root imports it, and the coverage build never compiles it.
- The artifact uses LLVM and defaults to Debug with runtime safety. Only its root module
  drops error return traces, because Zig 0.16.0's test runner does not compile
  its fuzz loop with them.
- It does not link the shared `telar-core` module. That module imports every
  library, which brings the emulator's C++, FreeType and Wuffs, and `--fuzz`
  instruments C sources with sanitizer coverage callbacks Zig 0.16.0's fuzzer
  does not define: the fuzz build fails to link with undefined
  `___sanitizer_cov_trace_*` symbols. The target builds its own `core.zig`
  over `bytecodec`, `localsocket` and `cellcodec`, from a `Libraries` graph
  where `lib/unicode/fake.zig` stands in for `unicode`, as the `cross` checks
  do. No client message lays out text, so widths do not matter here.

## Limitations

- The coverage number in the fuzzing report counts the whole executable,
  test runner included. It says nothing about how much of `decodeClient` ran.
- The fuzzer mutates whole payloads. It reaches a deep field only by mutating
  a seed that already gets there, which is why the seeds carry every optional
  part and collection. A NUL inside an import command was not found in
  200,000 runs; a seed found it. Likewise, with the decoder's source check
  removed in a scratch copy and the seed "import_history with a NUL in
  source" taken out, 6,009,254 runs did not produce a rejected source; with
  the seed in place the replay fails at once. Some contracts are held by the
  seeds, not by fuzzing.
- Prefix checks try three cut points per accepted payload, not every one.
- Text contents are checked only as far as the round trip reaches them: a
  value both the decoder and the encoder accept passes, whatever it means to
  the runtime.
- The server decoder, frames, `cellcodec` and text metadata have their own
  targets and are out of scope here.
