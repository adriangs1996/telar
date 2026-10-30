# Native control protocol: ownership and security review

Acceptance remains open. This report separates tested invariants from code inspection and unresolved resource limits. It does not certify the whole terminal or the external VT archive.

## Ownership boundaries

| Resource | Owner and lifetime | Borrow / invalidation rule |
| --- | --- | --- |
| Fragmented control input | `control::Parser`, inline 256 bytes then allocator-owned vector | `Sequence` views exist only during synchronous consumer calls. A blocked request retains its own bytes unchanged. |
| Ordinary input | PTY read buffer or terminal pending-input queue | VT writes and callbacks finish synchronously before the producer lease is reacquired. |
| VT state | External terminal; `VtState` owns copied epoch caches | C API cell/style/grapheme views are used synchronously; mutation/resize invalidates caches. No pending reply retains a VT view. |
| Encoded responses | `Reply`, then immutable shared storage retained by `PtyResponseQueue` | A queue head/batch is borrowed by one consumer until consume/clear/close. Appenders cannot overwrite borrowed slots. |
| Graphics acknowledgements | Single-producer `ResponseOutbox`, inline 2 KiB then allocator-owned storage | Complete records are copied into the shared queue once. The worker retains unpublished records, never replays their commands, and releases storage after publication or cancellation. |
| PTY write offset | `Pane` and the queue's single consumer | Partial `writev` and EAGAIN retain unwritten bytes. Deferred parsing resumes after consumption. |
| Desktop request | `Clipboard::Pending`, copied metadata and payload, value ticket | Client and pane identity/generation, nonce and deadline must match. Focus changes cannot retarget an existing request. |
| Desktop frame contents | UI job owns copies before the decoded frame arena is reused | Deferred consent/provider calls never capture frame spans. Connection epoch and `QPointer` checks follow reentrant calls. |
| Clipboard provider | Client-side resource, accessed only after an execution grant | Consent/preparation alone does not read the resource. MIME snapshots check invalidation after lazy calls. |
| User paste | Client owns the gesture's listing/text choice and returned Qt values | Destination pane generation and connection epoch are captured before a lazy read and rechecked afterward. Listing reads no representation. MIME invalidation cancels the gesture. |
| Session permission | Runtime grants table, client generation and operation scoped | Disconnect/reset revokes it; no global grant or cross-client reuse. |
| Graphics query buffers/codecs | Controller vectors and bounded codec allocators | Per-pane usage is shared with `PaneMedia`; all panes share the runtime media budget. |
| Shared media account | `PaneMedia` allocator and its usage counter | Terminal borrows it and is destroyed first. Retired workers retain `PaneMedia`; runtime budget outlives both. |
| File/shared/temp resources | RAII descriptors, mappings, cleanup objects | Paths are owned during use. Temp cleanup verifies descriptor identity and UID before unlink. |

The clipboard execution grant is the authorization commit point. The runtime rechecks route, liveness and deadline immediately before sending it. Reset, timeout and disconnect cancel work before that grant. A committed effect which has already started cannot be undone; stale results are discarded. Cancellation messages preserve their ticket by value after pending request storage is released.

Desktop clipboard callbacks contain allocation failures across admission,
completion, execution and paste reads. The failure path invalidates its epoch
and shuts down its owned socket without allocating another response or retrying
the effect. Deferred consent retains ticket/epoch and checks context lifetime;
obsolete failures cannot close a replacement connection. Real event and frame
allocation failures pass in Release and ASan/UBSan. Exact one-shot fault scope
and library exclusions are in `measurements/control-queries/desktop-allocation-validation.json`.

## Bounds and failure behavior

* Parser headers: 8 KiB; DCS: 1 MiB plus header; OSC: 8 MiB; APC: 65 MiB. Over-limit input enters a discard state and recovers at a terminator/cancellation. These buffers also consume the runtime allocator's 2 GiB budget; that process-wide number does not bound Qt allocations in the separate client.
* Terminal deferred input: 128 KiB. Read interest stops while native control is backpressured.
* PTY response queue: 64 messages, 1 KiB inline per slot, 2 MiB retained response bytes. Native replies retry without replaying setters or appending after publication. No callback waits for the same thread to consume the queue.
* Graphics acknowledgement outbox: 2 MiB including length headers, at most 1 KiB per record. Allocation failure or overflow closes the affected pane generation explicitly. The foreign callback contains exceptions; the enclosing write observes failure after returning from C. `stopProducing` rejects publication without clearing a buffer which the runtime may still borrow for `writev`; only the consumer closes/clears it. Worker priority yields native producer leases while ACK records remain staged. A drain job is scheduled only when its next complete record fits and never re-executes image/file operations.
* Clipboard content: 1 MiB aggregate owned content; write transaction: 64 MIME entries and 64 aliases. Read request: four MIME entries; wire completion: four contents and sixteen formats. Metadata and encoded input have independent checked bounds.
* Clipboard pending request: one controller request, 30-second deadline, two bounded response staging slots. Session grants: 32 routes. GUI connection: 32 pending jobs.
* Graphics: configured global and pane accounting, image dimension maximum 10,000, bounded PNG/zlib allocators and checked sizes. Quiet queries still validate and consume temporary/shared resources before suppressing responses.
* EOF, fatal write failure and deferred allocation failure permanently close the native controller and shared response queue. Late worker callbacks cannot repopulate the closed generation. Owned control buffers are released without allocating. Other panes remain usable.

Memory usage is charged under the existing global media mutex. Each media allocator owns its own mapping table; sharing a usage counter does not share mutable mapping records. The worker never accesses the native controller's buffers. The queue mutex protects publication/consumption and permanent closure. The native producer lease is released before external VT writes and before aborting.

## Executed validation

The focused tests cover retained response ownership, queue contention, every parser split in differential fixtures, bounded parser fuzzing, ignored-control permission bypasses, foreign callback spies, immutable pending replies, stale clipboard routes, consent and execution ordering, reentrant MIME invalidation, deferred allocation failure, configured codec budgets and resource cleanup. The exact current build/test runs are recorded in `measurements/control-queries/security-validation-current.json` once completed.

The prebuilt VT archive, system libraries, Qt and platform clipboard implementations are outside the C++ sanitizer instrumentation. Passing these tests is not a proof of their internal memory safety. Rosetta executions establish x86 test behavior, not native x86 performance.

## Unresolved acceptance gates

1. **Qt clipboard materialization precedes the transport bound.** An in-memory `QMimeData` test supplies 16 MiB; the provider rejects the result against its 1 MiB bound only after Qt materializes those 16 MiB. No real host clipboard is used. The existing public Qt/Cocoa whole-value getters do not provide a verified preallocation size/streaming contract for arbitrary MIME values. A separate resource probe tried 96 MiB `RLIMIT_AS` and `RLIMIT_DATA`; both returned EINVAL on this host and a 128 MiB touched allocation succeeded. This proves those two exact experiments failed, not that every possible isolation design is impossible. A bounded provider/isolation design remains required.
2. **Resource scheduling measurements.** Sequence boundaries now yield after each graphics command, including quiet queries, before admitting later input. Complete quiet atomic envelopes retain their direct path in groups of at most eight and 128 MiB of declared raw data. This is a bounded count/size admission rule; it does not establish a hard filesystem wall-time deadline or bound all copy traffic to 128 MiB. A failed direct import followed by fallback may copy again. Worst-case work and complete allocation/copy accounting remain to be measured.
3. **PNG decoder coverage.** The Wuffs adapter now matches actual application completion semantics in 68,672 split cases, including complete pixels without IEND. Generic codec internals remain outside C++ sanitizer instrumentation; see `measurements/control-queries/wuffs-png-review.md` for exact allocation bounds and independent pixel checks.
4. **Coverage and performance certification.** The actual Surface clipboard fixture now checks 44,815 split cases without a difference, separately from 48,107 stream cases. Real PTY tests verify both ACK/DSR orders and 5,000-response retention in seven pairs; remaining lifecycle cases and final allocation/copy accounting are incomplete. Existing paired measurements include material regressions against the actual Ghostty application handler. No waiver is inferred from the default clipboard policy.

The previous ACK/DSR inversion is reproduced against the frozen original Telar
daemon and fixed by forwarding only the native parser's consumed raw prefix to
the media worker. Native parsing resumes after that prefix and its pending ACKs
finish publication. A borrowed, statically dispatched `PaneMedia` port is owned
by the same Pane, which destroys Terminal first. Overflow of ordered output or
resize events closes explicitly even without an active worker completion.
`media-boundary-validation.json` records six Release/sanitizer suites, broad
runtime runs, diagnostic direct/coalescing counters, parser Rosetta behavior and
x86 object compilation. Shared imports now use the checked descriptor reader;
PNG mutable input state lives outside the function containing setjmp, preserving
allocator validity during error cleanup. All tests use owned synthetic resources.


The follow-up process-limit experiment installs and verifies a valid AS limit,
found by binary search against the actual initial map instead of assuming a
96 MiB total process. `clipboard-mach-limits.json` records the source/binary,
compiler, host/kernel, exact command and raw values. With 8 MiB headroom, malloc
and mmap 32 MiB fail with ENOMEM, while a synthetic queued Mach OOL receive maps
16 MiB and leaves VM above the installed limit. The physical-footprint setter
for this disposable process returns KERN_NO_ACCESS(8). No privilege escalation
was attempted. Earlier rendezvous versions timed out and are not evidence for
OOL enforcement. No real clipboard or other session was contacted.

This blocks accepting an RLIMIT-only Qt helper as a bounded-memory solution.
It does not prove all alternative platform adapters impossible. A helper can
still bound IPC, wall/CPU time and GUI responsiveness; its memory bound needs
a different, verified mechanism. Native Wayland/X11 bounded reads and a macOS
resource adapter remain possible engineering directions, not implemented
protections. The existing Qt materialization issue remains an acceptance gate.
