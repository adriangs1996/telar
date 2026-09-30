# Fuzzing server IPC decoding

`src/core/schema/messages/server_fuzz_test.zig` fuzzes `decodeServer` and
`decodeServerInto`, the dispatch a client runs on every message the runtime
sends. It uses Zig's built-in fuzzer (`std.testing.fuzz`) and needs no other
tools. The step is `test-fuzz-ipc-server`, registered by
`build/fuzz_ipc_server.zig`.

It checks telar's own decoders for robustness and regressions. Every input is
synthetic and built in memory: no socket, runtime, window, clipboard, file or
network is involved, and no decoded message is dispatched.

## Scope

Covered: the server tag switch, every server body decoder it reaches, the
trailing-bytes check, and every view an accepted message exposes (pane
descriptors, history entries, tab descriptors and their foregrounds, agent
entries, workspace and worktree lists, layout tabs and their nodes, search
matches, history stats rows, path matches, frame spans, their cells and text
metadata runs and links).

Not covered here:

- Client IPC decoding (`decodeClient`) and the handshake, which has its own
  target.
- Deep frame, cell and text metadata decoding. Frames are decoded and walked
  as a client consumes them, but mutation targets for `frame_support`,
  `cellcodec` and the metadata view belong to their own fuzz target. Pane
  frames are not re-encoded, because cell runs may carry a redundant style
  and so do not re-encode byte for byte.
- What a client does with a message, runtime state and model transitions.

## Properties

Each payload, fuzzed or seeded, must satisfy all of these; the fuzz test
panics on the first one that fails, so the fuzzer keeps the input.

1. **One answer from both APIs.** `decodeServer` and `decodeServerInto`
   reject with the same error, or accept the same variant with the same
   semantic fields. `decodeServerInto` decodes into a destination filled with
   a byte pattern, then again over the message it just wrote. Fields are
   compared by meaning, never as raw bytes: capacity arrays compare their
   occupied part (`ClientList.entries[0..count]`, `ClientCommand.text()`,
   `comments()`, `ShmName.slice()`), cells compare with `Cell.eqlPublic`,
   unions compare their active tag and payload. After a rejection the
   destination holds no valid message, as `decodeServerInto` documents, and
   nothing reads it.
2. **Views are legal.** Every view of an accepted message is iterated from
   both decodes in lockstep. It yields exactly its declared count, and a
   complete walk consumes exactly the bytes the decoder delimited. Every
   non-empty slice lies inside the payload. How an iterator may fail follows
   what its decoder validated:
   - validated in full (tab snapshots, workspace snapshots, agent snapshots,
     workspace lists, layouts, search matches, path matches, frame spans):
     never;
   - boundaries only (history entries, history stats rows): validation
     errors, never `Truncated`;
   - sizes only (cells, read by `CellReader`): any error, as the consumer's
     own rejection.
3. **Truncation and trailing bytes.** Every proper prefix of an accepted
   payload fails with exactly `Truncated`, and the payload with one more byte
   fails with exactly `TrailingBytes`. Decoders read fields in an order the
   bytes already read decide, and `decodeServer` checks the end after the
   message, so this holds for every tag but `request_failed`, whose text runs
   to the end of the payload; for it only prefixes shorter than its fixed
   head are checked.
4. **Round trip.** A message whose views iterate completely goes back
   through its tag's encoder (views are collected into fixed arrays first) and
   must produce exactly the payload. The encoder may refuse only what
   `encoder_rejections` lists.

The oracles are the other API, the encoders, the byte structure and the
views' own iterators, not a copy of the decoders.

## Findings

Two decoders accept values their encoder refuses. Neither is a crash; both
are listed in `encoder_rejections` and pinned by seeds, so a change on either
side shows up:

- `history_output`: `decodeHistoryOutput` checks only the content length;
  `encodeHistoryOutput` also refuses a NUL byte (`EmbeddedNul`). Minimal
  input: the `history_output` seed with its last content byte set to `0x00`
  (seed `history_output_nul`).
- `history_stats_result`: `decodeHistoryStats` and
  `HistoryStatsTopIterator` check only the command length;
  `encodeHistoryStats` also refuses a NUL byte. Minimal input: one row whose
  command is `"\x00"` (seed `history_stats_nul_command`).

Whether the decoders should refuse NUL or the encoders should allow it is not
decided here; production code is unchanged.

## Corpus

Seeds are built at test time by telar's own encoders, so they follow the
encodings as they change. `every server tag has an accepted seed` fails when a
tag gains no accepted seed.

- **Accepted, one or more per tag, all 50.** Variants with their own seed:
  empty and one-entry client lists and a full one (8); requested and applied
  client commands; change review snapshots empty, with one comment and with
  the 32 allowed; snapshot and patch frames (the patch has no metadata);
  exited and running pane text; set and cleared titles; search matches at 0,
  2 and 64; progress in set, indeterminate and error states; tab snapshots at
  0, 2 and 64 panes; automatic and labelled tabs in a workspace and a
  worktree; tab closes with and without a workspace closure; every graphics
  message; request failures with text and empty; bound and disabled proxy
  status; notifications targeting a pane and none with a link; ready and
  unavailable suggestions; opened and missing editors; path results at 0, 2
  and 50; history results at 0, 1 and 100; history stats at 0, 1 and 10;
  workspace snapshots with no tab, one tab with a foreground in a worktree,
  and 64 tabs; workspace lists empty, with a worktree and with 64 entries;
  agent snapshots at 0, 1 and 64 entries; unrestored, split and 64-tab
  layouts; focused and unfocused focus results.
- **Rejected:** the empty payload; unknown tags `0x00`, `0x01` (a client
  tag), `0x42`, `0x80`, `0xb5`, `0xff`; a pane count over its bound, past the
  end of the payload and short of it (`TrailingBytes`); an unknown lifecycle;
  a duplicate pane; a zero request id; a boolean flag of 2; a length past the
  end; a tab out of position; too many history results and client list
  entries; too many review comments; an unrestored layout with a width; a set
  progress without percent; an image whose length does not match its size;
  a trailing byte.
- **Accepted, then refused by a late consumer:** a history entry with an
  unknown status, a stats row with an empty command, a frame whose first cell
  needs a previous style.
- **Accepted, then refused by the encoder:** the two findings above.

Seeds larger than the fuzzed payload (the 100-entry history results, the
64-entry agent snapshot and the 64-tab layout) run through the same
properties in `every server fuzz seed reaches its verdict` but stay out of
the fuzz corpus, because `Smith.slice` would cut them to nothing. Every
proper prefix of an accepted seed is itself a truncation case, so each valid
seed also exercises all of its truncations.

A tag with an accepted seed is reached, not covered in depth: the fuzzer's
program-counter count covers the whole test executable, including the
runner, so it is not decoder coverage either.

## Bounds

- The fuzzer builds payloads of at most `payload_capacity` (2048 bytes); the
  largest directed seed is under `directed_capacity` (16 KiB).
- An input applies at most four patches; an insert stops at
  `payload_capacity`.
- Every check is bounded by the payload: prefix checks decode at most
  `payload.len` prefixes, iterators stop at their declared count, collection
  arrays have the protocol bounds and fail instead of growing.
- Buffers of kilobytes (the `decodeServerInto` destination, the collection
  arrays, the re-encoding buffer) are file-level and filled before every
  read, so the fuzz loop allocates nothing.

## Fuzz input

One input is a payload (`Smith.slice`, at most 2048 bytes) followed by up to
four patches, read while `Smith.eos` says the input goes on. A patch is a
kind (set a byte, write a little-endian u16 or u32, truncate, insert a byte),
an offset wrapped into the payload and a value weighted toward 0 to 257,
`0xffff` and `0xffffffff`, where counts, lengths, flags and tags live.

Zig 0.16.0's fuzzer mutates a slice as a stream from its first byte: random
bytes land where the output currently stands, after copies of at most 8
bytes in most mutations. A change deep inside a seed is therefore rare. With
the payload alone, a decoder weakened to accept a NUL in `pane_cwd` went
unfound for 2M runs; with patches, whose integers the fuzzer mutates one by
one, the same defect was found in about 12K runs from an empty fuzz cache.

A seed is only a payload, and past the end of the input `eos` is true, so
seeds and saved crashes replay unchanged.

## Build

`build/fuzz_ipc_server.zig` reuses `Modules` and `Libraries` and builds its
own `telar-core` module from `src/core/core.zig`, importing only the
libraries `src/core` imports (`bytecodec`, `cellcodec`, `cellgrid`,
`keyinput`, `kitty_protocol`, `localsocket`), with `unicode` bound to
`lib/unicode/fake.zig` through `Libraries.create`, as the unicode
substitution test does.

The application's core cannot be used as it is. `zig build --fuzz`
instruments every C and C++ object of the executable, and the application's
core reaches the emulator's C++ through `cellgrid` and `unicode` (and links
freetype and the rest through the other libraries). Zig 0.16.0's fuzzer then
fails twice: the link misses the `-fsanitize-coverage=trace-cmp` callbacks
(`__sanitizer_cov_trace_cmp1` to `8`, `const_cmp1` to `8`, `trace_switch`),
which it does not define, and with those stubbed the instrumented binary
aborts at start with `pc counters length and pcs length do not match
(262121 != 13846)`. The fake width table changes nothing this target
exercises: no decoder or view asks `unicode` for a width; only cellgrid's
buffer writes and text layout do.

## Commands

The step is not wired into `build/tests.zig` yet. Until the shared wiring
lands, apply the integration patch first:

```sh
git apply /tmp/dispatch-claude/robustness-fuzz-ipc-server-integration.patch
```

It adds `const fuzz_ipc_server = @import("fuzz_ipc_server.zig");` and
`fuzz_ipc_server.add(b, app.modules);` after the handshake target. Then:

```sh
# Seeds and properties, no fuzzing.
zig build test-fuzz-ipc-server -Dgui=false -j1

# A bounded campaign; the limit takes K, M and G suffixes.
zig build test-fuzz-ipc-server -Dgui=false -j1 --fuzz=10K
```

The target has the handshake target's Zig 0.16.0 constraints: LLVM is chosen
explicitly, only its root goes without error return traces (runtime safety
stays on), and a broken property panics so the fuzzer keeps the input.

Read the output, never the exit status: a found failure still leaves
`zig build --fuzz` exiting 0. A failure prints `server message property
failed: <error> for payload <hex>` and `input saved to
'.zig-cache/f/crash'`. Each report shows `Runs: <before> -> <after>`;
counts accumulate while `.zig-cache/f` is kept, and restart from zero for a
changed test.

The saved `crash` file is the input in `Smith` form, but Zig 0.16.0 has left
it empty (0 bytes) for a crash found by mutation; the hex payload in the
panic message is the reliable reproducer, since a payload without patches is
a valid input.

To replay a failure, put its input next to the test, either the `crash`
file or `<u32 little-endian payload length><payload bytes>` rebuilt from the
panic's hex, and add `@embedFile("server_fuzz_<name>")` to `replayed_inputs`.
A plain `zig build test-fuzz-ipc-server` then runs it through the properties
in `every saved fuzz input keeps the properties`, and later campaigns start
from it.
