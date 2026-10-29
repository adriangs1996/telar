# Native control query contract

Status: implementation and validation in progress. Coverage, security and
performance gates remain open. This document is an acceptance ledger.

The task starts at Telar `2ac4d6016dd23592e61d7f03a4c24d83aab7ba9f`.
The application oracle is Ghostty
`df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137`, revalidated against the remote
main ref on 2026-10-29. The frozen baseline used VT dependency
`a4edca2a90d6cf89900bb058e71cb6860cec78c5`. The working implementation ports
only the state bridge to the same frozen application revision, correcting
non-query CAN semantics and versioning the extended C API. The original
baseline artifacts remain immutable. The VT and application oracle builds
have different purposes. No Zig Telar runtime
is an oracle for this task.

## Source map

All Ghostty paths and line numbers below refer to the application revision
above, under https://github.com/ghostty-org/ghostty/tree/df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137/.

| Key | Exact source |
| --- | --- |
| stream | `src/terminal/stream.zig`, actions 33–250, CSI dispatch 2085–2795, OSC dispatch 2880–3020, DECID/RIS 3246–3260 |
| framing | `src/terminal/Parser.zig`, `src/terminal/parse_table.zig`, `src/terminal/stream.zig:3370` |
| application | `src/termio/stream_handler.zig:198` (all application action dispatch), 415 (DCS), 512 (APC) |
| modes | `src/terminal/modes.zig:88` (report states), 218 (full-width query identifiers), entries table in that file |
| status | `src/terminal/device_status.zig`, `src/termio/stream_handler.zig:850` |
| strings | `src/terminal/dcs.zig:58`, 188, 260 (DECRQSS encoding) |
| capabilities | `src/terminfo/Source.zig` (`xtgettcapMap`), `src/terminfo/ghostty.zig` (entire capability table including generated key variants) |
| colors | `src/terminal/osc/parsers/color.zig`, `src/terminal/kitty/color.zig`, `src/termio/stream_handler.zig:1615`, 1858 |
| desktop | `src/Surface.zig:1039` (title), 1099 (OSC 52 read), 6400–6600 (clipboard permission and replies) |
| notifications | `src/termio/Termio.zig:771` (scheme), 805 (visibility), resize/focus/config mailbox consumers in `src/termio/Thread.zig` |
| checksum | `src/terminal/xt_checksum.zig`, `src/termio/stream_handler.zig:606` |
| clipboard | `src/terminal/osc/parsers/kitty_clipboard_protocol.zig`, `src/terminal/kitty/clipboard{,_command,_write,_response,_grants}.zig`, `src/termio/stream_handler.zig:1045–1477` |
| glyphs | `src/terminal/apc{,/glyph,/glyph/request,/glyph/response,/glyph/execute}.zig` |
| policy | `src/config/Config.zig:2458–2513`, 3046–3124, 3939 |
| PTY | `src/termio/mailbox.zig:67`, `src/termio/Termio.zig` (`queueWrite`), `src/termio/Thread.zig` (mailbox drain and write queue) |

## Exhaustive query families

Notation: CSI=`ESC [`, DCS=`ESC P`, OSC=`ESC ]`, APC=`ESC _`,
ST=`ESC \\`. Parameters are decimal unless explicitly hex or base64.
Every named case must be tested at every byte split, plus consecutive queries
and a mixed mutation/query stream. Families sharing an encoder still require
separate case results. A row marked pending blocks acceptance.

| Case | Input and variants | State, response and policy | Application source | Acceptance |
| --- | --- | --- | --- | --- |
| enquiry | ENQ (C0 05), including embedded C0 during CSI | Configured answerback, default empty; no desktop access | handler:921, Config:3939 | pending |
| da-primary | `CSI c`, `CSI 0 c`, other accepted parameter values; `ESC Z` DECID | `CSI ?62;22;52c` when clipboard write is not denied, otherwise omit 52 | stream:2085,3246; handler:825 | pending |
| da-secondary | `CSI > c` and parameter variants | Ghostty `CSI >1;10;0c`; Telar must identify its own implementation | handler:825 | pending |
| da-tertiary | `CSI = c` and parameter variants | Application deliberately sends no response (C API differs) | handler:825 | pending |
| operating-status | `CSI 5 n` | `CSI 0 n`; unsupported DSRs silent | handler:862 | pending |
| cursor-position | `CSI 6 n` | `CSI row;col R`, 1-based, subtract top/left margins with saturating arithmetic under DECOM | handler:850–885 | pending |
| cursor-extended | `CSI ?6 n` | `CSI ?row;col;1 R`, same origin rule and constant page 1 | handler:886–898 | pending |
| scheme | `CSI ?996 n` | Forced `CSI ?997;1n` dark or `;2n` light | handler:900; Termio:771 | pending |
| visibility | `CSI ?998 n` | Forced `CSI ?999;1n` potentially visible or `;2n` not visible; focus is independent | handler:902; Termio:805 | pending |
| ansi-mode | `CSI Ps $ p` | `CSI Ps;state $ y`; states 0 unknown, 1 set, 2 reset, 3 permanently set, 4 permanently reset. Fixed-reset ANSI modes 1,5,7,10,11,13–19 | stream:2358; modes:88 | pending |
| dec-mode | `CSI ?Ps $ p` | `CSI ?Ps;state $ y`; DEC117 permanently reset. All supported modes, disabled modes and unknown/high IDs through 65535 included; never reinterpret a high ID as ANSI | stream:2358; modes:88,218 | pending |
| version | `CSI > q`, `CSI >0q`, accepted extra parameter variants | `DCS >\|ghostty VERSION ST`; Telar name/version must be truthful | handler:976 | pending |
| size-pixels | `CSI 14 t` | `CSI 4;height;width t`; cell size × grid in wide arithmetic | handler:1848; size_report.zig | pending |
| size-cell | `CSI 16 t` | `CSI 6;cell_height;cell_width t` | same | pending |
| size-text | `CSI 18 t` | `CSI 8;rows;cols t`; works without pixel geometry | same | pending |
| size-screen | `CSI 19 t` | `CSI 9;rows;cols t`; Ghostty uses text area, not physical desktop | same | pending |
| title | `CSI 21 t` | Default deny. Opt-in `OSC l TITLE ST`; title must never inject terminal input | handler:1854; Surface:1039; Config:2513 | pending |
| keyboard | `CSI ?u`, accepted parameter variants | `CSI ?flags u`; active screen's Kitty keyboard stack; push/pop/set, alt screen and reset affect result | handler:961; stream:2670 | pending |
| checksum | `CSI Pi;Pg;Pt;Pl;Pb;Pr * y`, omitted/default parameters and page ignored | Default disabled. Opt-in `DCS Pi !~ XXXX ST`, uppercase 16-bit sum; origin/rectangle rules and all five flags; `CSI Ps #y` changes flags only when enabled | handler:606; xt_checksum.zig | pending |
| termcap | `DCS +q HEX[;HEX…] ST`, upper/lower hex | All keys and aliases in immutable Ghostty terminfo map, including generated key modifiers. One `DCS 1+r KEY[=VALUE] ST` per known key, hex bytes. Unknown keys silently omitted by application. Telar TN must match TERM; advertise only actual capabilities | handler:485; Source.xtgettcapMap | pending |
| status-sgr | `DCS $q m ST` | `DCS 1$r ATTRIBUTES m ST`, actual cursor attributes; default/reset/extended colors and underline variants | dcs:260; Terminal.printAttributes | pending |
| status-cursor | `DCS $q SP q ST` | `DCS 1$r STYLE SP q ST`, 1–6 reflect shape and blink | dcs:260 | pending |
| status-vertical | `DCS $q r ST` | `DCS 1$r top;bottom r ST` | dcs:260 | pending |
| status-horizontal | `DCS $q s ST` | `DCS 1$r left;right s ST` when DECLRMM; otherwise negative | dcs:260 | pending |
| status-unknown | Empty/unknown DECRQSS up to two bytes; longer payload | `DCS 0$r ST` for unknown supported-length request; overlong discarded | dcs:188,260 | pending |
| palette | `OSC 4;index;? [;index;?…] BEL/ST` | Current 0–255 palette; replies mirror terminator, 8-bit/16-bit/none format; ordered mixed setters and queries | handler:1615; Config:3046 | pending |
| special-palette | `OSC 5;index;? BEL/ST` | Recognized but unimplemented special colors: no response, like application | handler:1769 | pending |
| dynamic-colors | `OSC 10;?`,11,12 and chained selectors through 19; BEL/ST | Foreground/background/cursor supported, cursor falls back to foreground. Other dynamic selectors silently omitted. Set/reset in OSC 10–19/110–119 must affect subsequent queries | handler:1745; osc/color.zig | pending |
| kitty-colors | `OSC 21;key=?[;key=?…] BEL/ST` | Palette and foreground/background/cursor; aggregate `OSC 21;key=rgb:rr/gg/bb…` matching terminator. Unset cursor returns empty value (different from OSC12); unsupported special keys ignored. Set/reset mixed in request order | handler:1858; kitty/color.zig | pending |
| clipboard-osc | `OSC 52;selection;? BEL/ST` | Read defaults to ask; policy deny is silent, explicit user denial replies empty. Reads use standard desktop clipboard while echoing selection c/s/p (unknown kinds fall back to c); writes honor location. Strict alphabet accepts absent padding; no authorized client means no disclosure | handler:1045; Surface:1099,6400 | pending |
| clipboard-kitty-read | `OSC 5522;type=read[:metadata][;base64 MIME list] BEL/ST` | Permission denial EPERM, unsupported resource ENOSYS, failure EIO. Success OK, optional targets DATA, requested MIME DATA chunks, DONE. Targets-only does not consume one-time grants. IDs sanitized and bounded; strict UTF-8/base64 metadata/payload | handler:1076–1227; Surface:6447; clipboard_response.zig | pending |
| clipboard-kitty-write | OSC5522 write/wdata/walias/commit transactions | Related control acknowledgements: denied begin EPERM, invalid EINVAL, oversize EFBIG; commit permission/desktop failure. MIME aliases, replacement, cancellation, reset, session/one-time grants. Distinct from query read but affects permission/report state | handler:1230–1477; clipboard_write.zig | pending |
| graphics-query | `APC G a=q,…;payload ST`, quiet/id/format/medium variants | Own recognition, validation and response; generic file/shared readers and PNG/zlib codecs only, no external query handler and no duplicate interactive/media replies | handler:512; terminal/kitty/graphics.zig and exec.zig | pending |
| glyph-support | `APC 25a1;s ST` | `APC 25a1;s;fmt=glyf ST` in Ghostty. Telar may not claim rendering formats that clients cannot consume | handler:531; glyph/execute.zig:14,40; response:153 | pending |
| glyph-coverage | `APC 25a1;q;cp=HEX ST` | Actual session glossary coverage (system coverage is not populated by application stream handler); normalized lower hex in reply; register/clear affects result | glyph/execute.zig:48; response:184 | pending |

## Related reports and lifecycle

| Case | Trigger | Required behavior | Acceptance |
| --- | --- | --- | --- |
| scheme-subscription | DEC2031 set/reset/save/restore; theme config change; RIS | Send on externally changed theme/palette while subscribed; VT color setters do not send scheme notifications; reset clears subscription and session grants | pending |
| visibility-subscription | DEC2033 set/reset/save/restore; hide/show, attach/detach, disconnect | Initial report on enable, later actual visibility changes; no report after unsubscribe. Durable runtime view is aggregate visibility from eligible attached clients | pending |
| size-subscription | DEC2048 set/reset/save/restore; resize, owner change, disconnect | Initial in-band report then `CSI 48;rows;cols;pixel_height;pixel_width t` on resize; no client required for rows/columns | pending |
| focus-subscription | DEC1004 set/reset/save/restore; actual focus changes | Initial I/O report on enable and subsequent focus transitions. Never derive visibility from focus | pending |
| clipboard-paste-subscription | DEC5522 set/reset/save/restore; user paste, one-time password, read completion | Unsolicited OSC5522 targets listing replaces ordinary paste while enabled; one-time read grants do not survive reset or pane lifetime. Targets-only reads do not consume a grant. Actual source: `Surface.zig:6230,6347`, `terminal/modes.zig:410` | pending |
| reset | RIS, DECSTR, primary/alternate switch | Correct terminal state at stream position; clear the appropriate subscription, keyboard, checksum, client-operation and grant state; do not clear unrelated durable client facts | pending |
| client-operation-lifetime | queued/read/consent reply; disconnect, pane close/reuse, policy change | Owned bounded request and result; pane identity/generation, client identity/generation, request nonce and deadline all validated before completion; stale results rejected | pending |
| saturation | full PTY queue, partial writes, EINTR/EAGAIN, worker producers | Bound resources and pause ingestion before accepting additional responding queries. Same-thread callbacks never wait for the runtime consumer. No silent loss of admitted replies | pending |

Framing must account for the application's actual parser, not assumed xterm
behavior. At ground high bytes are UTF-8; C1 introducers act inside escapes.
OSC and DCS payload treat high bytes as data. APC drops bytes A0–FF and
accepts C1 ST; ESC/CSI and pre-hook DCS ignore A0–FF. CAN/SUB abort;
ESC leaves a string and is then the introducer of the next escape. The oracle
must distinguish termination from cancellation and document deliberate safer
behavior. Unknown sequences, binary data and over-limit strings must make
bounded linear progress and recover at a terminator or cancellation.

Tmux DCS1000p is an application integration/control channel rather than a VT
query family. Title push/pop, desktop notification, CWD, progress, keyboard
setters and graphics drawing are mutations. They remain inventoried as state
dependencies; they do not expand this task into a tmux client or renderer rewrite.

## Telar contracts and acceptance method

Telar owns query recognition, state, policy, encoding and PTY routing in C++23.
The VT adapter may read cursor, modes, colors, style and cells. It must never
ask the external library to parse or answer an intercepted query. Observers
consume mutations without producing replies. Media processing owns image work,
but query control and routing stay native. Dispatch is static, without virtual
interfaces. Borrowed views never outlive a synchronous call.

Identity uses Telar's build version and `TERM_PROGRAM=telar`; TN agrees with
the generic `TERM=xterm-256color` child environment. Visibility is the union of
explicit client visibility, with no clients meaning not visible. Theme selection
must have a deterministic per-pane authority independent of focus. Clipboard
and glyph/font resources belong to the client; runtime requests require explicit
grants and stale-completion checks. No test reads the host's real clipboard.

Freeze baseline and candidate executables separately with their SHA-256, source
manifest, compiler, flags, dependency hashes, hardware and load. Use the actual
application parser, handler, state and encoded queue bytes for the Ghostty
component oracle, and a real PTY for integration. A parser with an empty handler
cannot certify application performance. Compare independent fixture expectations
for deliberate Telar differences; never normalize away semantic mismatches.

Measure individual families, bursts, mixed streams, every-byte fragmentation,
unknown commands, long/binary payloads, saturation/recovery and ordinary text.
Use at least seven alternating pairs. Keep all samples and report wins, median
paired ratios, spread and response latency P50/P95/P99 separately. An improvement
requires six wins; a consistent loss in any control blocks acceptance unless
identical normalized assembly proves placement. Equivalence needs a stated
materiality margin and confidence interval, not a global average. Count allocations,
peak charged bytes, copies and CPU work separately from elapsed PTY latency.
Do not measure during builds/tests or present Rosetta timings as native x86-64.

ASan/UBSan, focused concurrency/TSan, adversarial parsing and partial-write tests
are required. Prebuilt VT/system libraries must be identified as outside sanitizer
instrumentation. Missing hardware or unsupported toolchain is reported explicitly.

## Preparation findings

The clean Telar Release build initially failed because Homebrew's common include
directory selected OpenSSL 4 headers while CMake linked OpenSSL 3. Isolated
dependency include prefixes fix the build without changing product sources.
The downloaded Ghostty source has dangling GTK symlinks; `build_ghostty.py
--source` follows them and fails. The baseline uses `git archive` to preserve
symlinks before applying the exact existing VT state patch.

The pinned application's build requires Zig >=0.17.0; installed Zig 0.16.0 builds
the pinned production dependency but cannot compile this application revision.
A private downloaded toolchain is verified against the official index hash.
Preparation failures and build logs stay under `dependencies/` and are not
reported as passing validation. Existing historical Zig comparisons in
`performance.md` and `parity.md` do not certify this task.

The compiler requirement is specifically the 0.17 series, not any newer Zig.
The private 0.17.0 archive has SHA-256
`b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a`,
matching the official download index. A first 0.18 development download was
not used as the accepted toolchain.

The frozen Telar binary has SHA-256
`df1438ba4ad5e6763562a2f1aef8e7c1ba2a2a271f7c46c0c56aee80d2e9446d`.
`measurements/control-queries/baseline-telar.json` records its compiler, flags,
cache/command-manifest hashes, VT dependency hash and machine (M1 Pro, 32 GiB).
The frozen files are in `dependencies/control-baselines/telar/` and must not
be overwritten when building candidates.

The direct terminal probe reproduces the existing gaps byte for byte in
`baseline-reproductions.json`. The real isolated PTY reproduction passes in
`baseline-pty-live.json`: 65-query bursts return 64 replies, recovery returns
one reply, a second burst returns 64 replies, and subsequent input is usable.
This is a successful reproduction of a defect, not accepted query behavior.
Elapsed times in these functional fixtures are not performance evidence.
An initial runtime startup failure used an overlong UNIX socket pathname;
the passing fixture uses a private short path under `/private/tmp`.

## Historical baseline prerequisite (resolved)

The unmodified pinned application build reaches shader compilation and fails:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
```

`xcodebuild -showComponent MetalToolchain -json` reports build `27A266a`,
status `uninstalled`, for Xcode 27.1 (`27A9275`). Selecting OpenGL still
unconditionally compiles Metal shaders in upstream build wiring. A recorded
test-only build adjustment removes that unrelated shader dependency, but the
OpenGL application then fails in `pkg/opengl/egl.zig:99`: `eglGetPlatformDisplay`
expects a pointer while `EGLNativeDisplayType` is `c_int` on this SDK. The
experimental application-handler adapter encounters the same problem. It is
unbuilt and cannot serve as an accepted oracle or performance baseline.

`preparation-blocker.json`, the complete build logs and
`ghostty-oracle-preparation.patch` retain the attempts. Query parser, handler,
configuration and response-encoding sources in the reference remain unchanged.
No missing baseline is replaced by a libghostty-vt result or the installed
Ghostty 1.3.1 application, which is a different revision.

Adrian authorized installing only the missing Metal Toolchain. The component
installation and subsequent unmodified application-core ReleaseFast build
succeeded; `baseline-ghostty-application.json` records the command and archive
hash. The earlier failures above and `preparation-blocker.json` remain historical
evidence, not a current blocker. No Telar application was installed.

## Implementation in progress

The native controller implements CSI reports, DECRQSS, all 273 frozen termcap
keys/aliases, color reports, checksum, ENQ, keyboard and graphics queries.
File, temporary-file and shared-memory queries validate their own data, use
configured pane budgets, and never enter the VT query handler. Generic PNG and
zlib codecs receive bounded allocators. Native parsing owns fragmented requests
and retains admitted replies under queue pressure. Media and observation
consumers suppress intercepted queries and desktop subscriptions. Glyph support
reports an empty format set because the C++ client cannot render session glyphs;
this deliberate limitation is not literal Ghostty rendering parity.

`differential-mutation-header.json` records 2,339 passing cases, including seeded
mutations and foreign-callback spies. `differential-bulk-parser-splits.json`
records 38,855 passing executions for the subsequent parser experiment. Earlier
failing reports remain evidence of corrected defects. These are fixture counts,
not exhaustive coverage percentages. Checksum covers all 32 flag combinations;
identity, TN and no-client focus/visibility use independent expectations.

Desktop state and clipboard routing now carry pane/client generations and a
nonce. The UI sends consent before inspecting resources; the runtime checks a
fresh deadline and sends a separate execution grant. Reset, stale completions,
timeouts and disconnects revoke work before that grant. A grant already admitted
to the client's connection is the authorization commit; an effect that already
started cannot be undone. A received cancellation removes work that has not
started. Replies own immutable encoded storage before pending state is released.
Clipboard session grants are scoped to the client generation and operation.

Six focused native control targets pass ASan/UBSan with the pinned VT library
outside instrumentation. Queue ownership/concurrency passes TSan. Parser and
queue tests also pass x86-64 under Rosetta; this is not native x86 performance.
The offscreen Qt tests use only in-memory MIME objects, including a source that
invalidates itself during retrieval. The complete runtime suite passed after
the state-bridge port (process-local `ulimit -n 8192`). Later edits still require
their appropriate final checks.

Acceptance is blocked by actual unresolved work: Qt can materialize clipboard
contents before their 1 MiB transport bound is checked; worst-case graphics work measurements,
allocation/copy accounting and complete lifecycle
adversarial coverage remain open. The default clipboard policy is not weakened
to hide these issues.

`performance-component-complete-07.json` contains seven alternating pairs for
24 component workloads using the real application handler. Its scope is
exploratory despite the filename: no GUI/PTY or overall acceptance claim. It
measures a 12.064× checksum-screen ratio, 40.088× graphics-payload ratio and
1.102× ordinary-text ratio against Ghostty, with regressions in other families.
Subsequent parser experiments are retained separately and are not accepted by
averaging away short-query regressions. All inventory rows remain acceptance
gates; this checkpoint does not finish the task.


The clipboard differential oracle now dispatches the immutable application's
actual `Surface.handleMessage`, embedded clipboard request flow,
`completeClipboardRequest` and `denyClipboardRequest`, with memory resources
instead of the host clipboard. `experimental/ghostty_clipboard_fixture.zig`
documents the partial Surface/App fixture fields and borrowed mailbox lifetime.
The library and source/build hashes are frozen by `candidate-16-freeze.json`.
The earlier adapter that answered EPERM directly is retained as historical
limited coverage, not evidence for granted desktop operations.

`differential-clipboard-current-splits.json` compares 44,815 executions across
five permission/consent policies, OSC52 selectors and padding, binary data,
Kitty MIME aliases/listings, unsupported primary selection, malformed packets,
BEL/ST/C1 terminators and all two-fragment boundaries. All match byte-exact
responses and in-memory clipboard contents. The first run exposed 98 failures
in 855 cases; retained diagnostics are `differential-clipboard-before.json`.
Corrections include OSC52 empty user denial, standard-resource read routing,
optional padding/noncanonical tail bits, required-padding Kitty decode, and
rejecting data after terminal padding in the same wdata packet. Independent
padded wdata packets remain accepted. Client primary-selection support is
checked as a platform capability before prompting, without inspecting contents.

The six focused Release and ASan/UBSan targets and Qt offscreen test pass;
`clipboard-surface-validation.json` retains logs and limits. This fixture
settles one asynchronous operation before another starts. Real transport,
generation cancellation and concurrency are separate native tests, not
represented by these response comparisons. Actual Surface user-paste events,
Qt materialization bounds, final PTY/allocation
measurements and the remaining performance regressions are still open.

The bounded ACK outbox now retains non-query graphics responses without replay,
with exact-capacity scheduling, producer priority, explicit failure, and busy
worker cancellation. Six focused suites and the broad runtime suite pass in
Release and ASan/UBSan; diagnostic drain-only checks, queue TSan and x86 Rosetta
checks pass. `response-outbox-validation.json` records their precise scope.

`candidate-18-freeze.json` freezes the new binaries and source patch.
`performance-response-outbox-pty.json` measures seven alternating pairs against
the unmodified Telar C++ baseline: 500 samples per workload after 50 warmups,
actual child PTY write/read, P50/P95/P99, runtime CPU/RSS, and recovery after a
100 ms response-read pause. All seven native runs retain 5,000 of 5,000 DSRs;
all seven original-baseline runs retain 319. This is not a Ghostty application
PTY comparison. Individual/fragmented query regressions remain visible.
`performance-response-outbox-vs-17.json` and
`performance-response-outbox-vs-ghostty.json` retain component comparisons:
the safety change has costs and the actual application performance gate fails.

`candidate-19-freeze.json` adds a sequence boundary between native control and
the media worker. Tests now preserve both `image → DSR` and `DSR → image` reply
orders, across every two-fragment split and seven actual PTY pairs. Quiet queries
also yield. Verified complete atomic envelopes remain grouped, capped at eight
and 128 MiB declared pixels, preserving direct import and coalescing within each
group. This bounds admitted operations rather than promising a hard I/O timeout.
`media-boundary-validation.json` records ownership, resize overflow handling,
shared-reader and PNG cleanup checks, current differential suites, x86 objects
and Rosetta limits. New PNG comparisons expose 12 missing-tail differences;
the accepted-pixel completion rule still needs implementation.

`performance-media-boundary-pty.json` retains all raw samples and intervals.
All seven runs preserve both reply orders and all 5,000 saturation responses;
the original daemon inverts image-first ordering and retains 319 responses.
Single-query comparisons are noisy/inconclusive; 32-response round trips win
7/7 with a median paired ratio of 0.251159 against original Telar. This does
not replace the separate actual-application component comparison, which still
fails multiple workloads. There is no final task acceptance.


Candidate21 replaces generic libpng with the existing pinned Wuffs PNG codec
C API. All query parsing, validation policy and replies remain C++.
`wuffs-png-review.md` and `wuffs-png-validation.json` record 68,672 PNG split
comparisons with zero differences, exact pixel/cleanup tests, Release/ASan/UBSan
results, memory limits and seven-pair measurements. This resolves the new PNG
completion differences. Performance and integration gates remain open.


The long APC oracle additionally identified same-kind C1 introducers98/9e/9f
inside APC. Native parsing now ignores them, matching the immutable application
same-state/no-action table. Current evidence is in `c1-apc-validation.json`.
`borrowed-apc-experiments.md` records three rejected borrowing optimizations:
the large payload improved substantially, but unrelated consistent losses
failed the optimization gate. Their binaries and source patches remain frozen;
the productive parser retains only the functional C1 correction.
