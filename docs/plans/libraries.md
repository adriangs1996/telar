# Libraries out of the application

Target: every piece of code is one of three things.

- **State** lives in the process model: `RuntimeModel` or `ClientModel`, its
  tables and records.
- **Business rules** are flow procedures over that model, reached from
  `update`. A rule stays here even when it is pure: what an agent status
  means, which host is Claude, which client may focus a pane.
- **Everything else is a library**: a module under `lib/<name>/` with its own
  root, its own tests and its own build step, that imports only `std`,
  external dependencies and other libraries. It never imports `telar-core`,
  `model`, `telar-client` or a process package, so the compiler enforces that
  it holds no telar state and decides no telar policy.

Libraries cost nothing at run time: Zig compiles every module of an artifact
in one compilation unit, so a call into a library inlines like a call into a
sibling file. What they buy is a boundary the build checks, tests that run
without the runtime or a client, and code another project (or a future
extraction) can take whole, the way telar takes `ghostty-vt`.

A library is a cohesive unit with its own tests, not one file per helper:
the goal is about twenty libraries, not two hundred.

## How the code was audited

Every directory under `src` was measured for the modules and the other
directories it imports, then read and classified (state, flow, business rule,
pure library, library with I/O, adapter, glue, test). Facts behind the
proposals: outside `src/backend/runtime` no backend file references
`RuntimeModel`; `backend/pty`, `backend/engine` and `frontend/platform`
import no other telar module; `backend/history` imports only `ghostty-vt`
and `telar-core`; most edges between backend directories are small shared
types living in the wrong place (`pane/PaneKey.zig`, `history/ClientKey.zig`,
`agent/types.zig`).

## Libraries

Cut: what must move or be parameterized before the library compiles alone.

### Ready now (no cuts)

| Library | From | Imports |
| --- | --- | --- |
| `pty` (done) | `src/backend/pty` | std |
| `console` (done) | `src/frontend/platform` (tty, raw mode, resize watcher, fast writer, escape sequences) | std |
| `pi_rpc` (done) | `src/backend/engine` (Pi's JSONL RPC mode) | std; the `Purpose` enum became a parameter |
| `eventstream` (removed) | `src/backend/proxy/{sse,Decoder,SseEvent}.zig` | std; deleted with the provider observers |
| `h2frames` (done) | `src/backend/proxy/h2/{framing,Reader,streams,Tracker,HeaderField,HeaderBlock,PeerSettings,Settings}.zig` | std |
| `localca` (done) | `src/backend/proxy/{ca,Authority,AuthorityFiles,Pair,Resources,Roots,tls,Session,InterceptOptions}.zig` | std, tls |
| `mailbox` (done) | `src/client/execution/{GenericInbox,DrainBudget,Wakeup,ProducerTicket,InboxSnapshot}.zig` | std |
| `animate` (done) | `src/gui/animation` (springs, transitions, frame clock) | std |
| `gfx` (done) | `src/gui/layout` and `src/gui/render/{Rect,Color,Quad,RoundedRect,SpriteQuad}.zig` | std |

A library's name is the alias every consumer declares, so it must not be a
word the code already uses for values: `tty`, `inbox`, `animation` and
`layout` name fields and locals in dozens of files, which is why those four
became `console`, `mailbox`, `animate` and `gfx`. For the same reason a name
is a valid identifier (`pi_rpc`, not `pi-rpc`), so module, directory and
alias are one word.

### Small cuts

| Library | From | Cut |
| --- | --- | --- |
| `cellgrid` (done) | `src/core/ui` (cells, buffers, styles, geometry) | none; imports the `unicode` library, which replaced `src/core/unicode.zig` |
| `pacing` (done) | `src/core/time`, `src/core/pacing` | none; one library, seven files |
| `vtscan` (done) | `history/{KittyFramingCounter,OscScanner,InputScanner,escape,Event}.zig` | none; `osc.zig` holds `OscTracker` tests and stays for `command-capture` |
| `cmdcapture` (done) | `history/{terminal,TerminalTracker,OscTracker,osc,Clock,Command,OscCompletion,TerminalTrackerConfig}.zig` | none; agent screen detection (`agent_detection`, `codex_screen`, `prompt_scan`, `Sample`) stays in history because it reads telar's agent manifests |
| `history-store` (not a library) | `history/persistence`, history worker and service | its schema is telar's history model (panes, tabs, workspaces, authors, origins); only the SQLite binding was mechanism, and it is `sqlite` |
| `sqlite` (done) | the three `@cImport("sqlite3.h")` in `history/persistence/sqlite.zig`, `agent/session_readers/codex.zig`, `agent/session_readers/session_readers.zig` | one binding plus the statement and migration helpers; the history schema and row mapping stay in `history/persistence/history_sql.zig`. A typed wrapper over the raw `c` calls in `Store.zig` is still open |
| `agentfiles` (done) | `agent/transcript.zig`, the Claude and Codex readers in `agent/session_readers` | the watch, job and completion stay; `agent/description.zig` generates titles with telar's prompt and stays |
| `jsonl` (done) | `agent_panes/{Stream,OutputFrame}.zig` and the JSON helpers of `agent_panes/protocol.zig` | agent panes, its only consumer, were removed later; the library stays for the next JSON Lines reader |
| `kitty-media` (not a library) | `src/backend/media` | measured, it is the runtime's graphics actor: telar's atomic shared frames, file queries the pane answers after validating the file, shared-memory placeholders freed through a per-pane quota, and protocol images and placements. Its mechanism moved instead: PNG decoding goes through `imaging.png`, which bounds dimensions before allocating; the image format is `kitty_protocol.Format`; and control fields are read with `kitty_protocol.ControlFields` |
| `vtgrid` (done) | `pane/{blit,damage,Diff,Cursor,BlitPane}.zig` | `collectSpans` is generic over the span type and takes the header cost; the search is generic over the match type and `SearchLimits`; callers count profiling. Selection moved to `cellgrid`. `TextDump` belongs to the pane and stays |
| `checkpoint` (not a library) | `src/backend/persistence` | it is telar's session format (providers, tab labels, the legacy pane kind it skips); its codec is `bytecodec` |
| `localsocket` (done) | `transport/{LocalListener,local}.zig` (both sides) and `src/core/transport` | none; the handshake stays in the app because it speaks telar's wire |
| `editorremote` (done) | `editors/{remote,expressions,Target,Candidate}.zig`, `core/editor.zig` | the search works on its own candidates and reports an index; the runtime job keeps panes and the reply |
| `hostmetrics`, `gitstatus` (done) | `runtime/observability/{Sampler,system_metrics,darwin,Raw,Values,SystemMetricsSample}.zig`, `runtime/resources/git_probe.zig` | the probe interval and the per-workspace completion stay in the runtime |
| `imaging` (done) | `src/gui/image` decoders and box filter | PNG now decodes through Wuffs; sprites and the favicon worker stay in the GUI |
| `cellglyphs` (done) | `src/gui/text/{Box*,Block*,block_shapes,Braille*}.zig` | `QuadList` joined `gfx`, which owns the quad format and now the diagram slot count; the ink paints a cell rectangle and a color instead of telar's `TextRun`. The box raster cache and the atlas stay |
| `mdinline` (done) | `gui/widgets/{MessageSpan,MessageSpans,MessageSpanScope,MessageLinkDestination}.zig` | the URI recognizer it borrowed from core became `urlscan` instead of being inlined, since the model and client use it too. Agent messages, its only consumer, were removed later |
| `keyinput` (done) | the key values in `model/input`, `client/input/{GenericRouter,GenericKeymap,encoding_support,mouse_protocol,PixelProjection}.zig`, `core`'s `InputModes` and `MouseTracking` | the key types moved instead of becoming parameters; the lease cap and timeouts joined `RouterLimits`, and telar's defaults stay in `model/input/keybind.zig`. `action_routing` is telar's repeat policy and stays; `edit.zig` tested the text field, now `textfield` |
| `console` additions (done) | `frontend/presentation/{Screen,screen_support,GenericInput,Parsed,KittyModifierEvent,pointer,PatchSink,Position}.zig` | the host input decoder and escape writers joined `console`; `Screen` became `GenericScreen` over the pointer enum, the model's damage rows and `diff.syncRow` joined `cellgrid`, and the Presenter counts flushes. `frame.zig` adapts protocol frames and stays |
| `kitty_protocol`, `textraster` (done) | `src/kitty_protocol` and the rasterizer, surface and rounded fill of `frontend/graphics` | the rasterizer takes the caller's font and `freetype` is an external; bilinear sampling and premultiplication joined `imaging`. The codec keeps telar's byte budget and z limits, and the renderers read the model, so both stay |

### Larger cuts

| Library | From | Cut |
| --- | --- | --- |
| `httprelay` (done) | `proxy/http`, `proxy/h2/{relay,connection,Observer,Transcoder}.zig` | every file tagged events with `agent/types.ApiDialect` and `middleware.Phase`; the relay now reports neutral stages and telar maps them to phases |
| `exchangecapture` (done) | `proxy/capture` | `Half` embedded a telar pane and credential; it now carries the caller's comptime `Meta`, and the credential gate stays in telar's `Channel` |
| `bytecodec` (done) | `schema/{Encoder,Decoder,wire}.zig` | none |
| `cellcodec` (done) | the cell run half of `schema/frame_support.zig` and `FrameView`'s cell iterator | the frame's size budget becomes a limit the caller passes |
| `syntaxhl` (done) | Syntax roles, language lookup and capture values | The native diff highlighter and its Rust dependency were removed with Reviews; theme syntax roles remain. |
| `mermaid` (done) | `gui/diagrams/{protocol,Image,worker,ProcessTask}.zig` | the library runs a caller-named helper with a deadline and validates its pixels; the texture store, service, helper path and theme mapping stay in the GUI, and the store now takes an opaque owner key instead of an agent message identity |

What stays in `telar-core` after the cuts: agent manifests and providers,
plugin manifests and capabilities, proxy and editor protocol values, history
filters and fuzzy matching, and the protocol in `src/core/schema`. The
schema was listed as a `wire` library, but 145 of its 192 files are telar's
messages (workspaces, tabs, agents, approvals) and it imports
some twenty of core's domain values; its field codec (`GenericDerived`)
switches on telar's ids and enums. Only its byte codec and cell encoding are
mechanism, and those are `bytecodec` and `cellcodec`. Core imports them,
`cellgrid` and `pacing` where its own values need them and republishes none
of them: every package imports the libraries it uses by name.

## Business rules that must move into flows, not into libraries

- `src/backend/agent/tracker_support.zig` (resolved): measured, it was the
  tracker's 60 scenario tests plus one enum, not a runtime flow. They are
  `runtime/tests/agent_status_test.zig`.
- The agent tracker (resolved): `RuntimeModel.agents` was a `Tracker`, a
  model nested inside the model. Its table (`Agents`), pending restores,
  session-file watches and revisions are `RuntimeModel` fields, and its
  methods are `runtime/agent_status.zig` procedures over `model`. `Agent`
  keeps the transitions of its own row (`applyProcess`, `applyProxy`,
  `reproject`...), as a pane record keeps `applyFrame`: they read and write
  that one aggregate and no other table.
- `src/backend/runtime/attachment/media_projection.zig` (resolved): it
  decided freeze and adoption across every client's attachment store. It is
  `pane_graphics.synchronize` and `discardUnwanted`, and its private
  `wanted` was a second copy of `Consumers.wants`.
- `Pane.queueGraphicsLimitResponse` (resolved): measured, it was a dead copy
  of the reply the media processor sends; that reply is
  `kitty_protocol.writeError`, whose detail is comptime and holds no control
  bytes.
- `ClientModel` kept flow logic inline (resolved): 110 of its functions
  were flow procedures already taking `model`. They live in their flow
  files (`copy_mode`, `pane_focus`, `pane_input`, `pane_attachment`,
  `agent_panes`, `tab_creation`, `workspace_handoff` and the rest), and
  `ClientModel.zig` went from 2,834 to 359 lines: the fields, their
  construction, `version` and the lookups every flow shares.
- Provider policy in the proxy (`proxy/provider/*`: which hosts are Claude or
  OpenAI, which routes are inference, what an Anthropic turn end looks like)
  stays in the app as business rules; the relay libraries receive it as data.

## Duplicates and misplacements found

- Two PNG decoders (resolved): `src/gui/image/png.zig` was a hand-written
  decoder over `std.compress.flate`; `imaging.png` now reads only the IHDR
  to enforce limits and hands decoding to Wuffs, the decoder the runtime
  already installs into the emulator from `src/backend/media/png.zig`.
- Three SQLite bindings (listed above).
- The two proxy channels (resolved): `src/backend/proxy/Channel.zig` and
  `src/backend/proxy/capture/Channel.zig` duplicated one bounded queue over
  two payload types. The queue is `dropqueue`; each channel keeps only the
  credential gate and what its payload owns.
- Two different types named `SessionTitle` (resolved): history's row, with
  its session id and pending or failed placeholders, is `StoredSessionTitle`;
  the durable title a checkpoint carries stays `agent/SessionTitle`.
- `src/core/select.zig` (resolved): the history filters had already left;
  the selection model, `Range` and `ClickTracker` are `cellgrid.selection`,
  `cellgrid.SelectionRange` and `cellgrid.ClickTracker`.
- `src/model/types` (resolved): its 86 files are gone. Measured by who names
  each type, three had no user and were deleted; 31 had one user and are
  private declarations in it, 18 of them in the client flow that was their
  only reader; 51 that several files name live beside the flow or table that
  owns them, and `Action` is declared in `input/action.zig`, the module that
  already published it.
- `src/gui/experiments` (resolved): measured, `frame/` is reached, since
  `run_widget.zig` builds the frame composition lab from it; `review/` lost
  its entry point when `run-widget` moved to that lab, nothing compiled or
  tested it since, and it is gone.

## Order

1. Set the pattern with the libraries that need no cuts: `pty`, `console`,
   `pi_rpc`, `mailbox`, `animate`, `gfx`. Each move adds `lib/<name>`, a
   module and a test step in the build, and a boundary check that fails if
   the library imports a telar module. Done; the pattern lives in
   `build/Libraries.zig`.
2. Shared low layers: `cellgrid`, `pacing`, `vt-scan`, `sqlite`, and a
   decision on the PNG decoder. `cellgrid`, `unicode`, `pacing`, `vtscan`
   and `sqlite` are done, and PNG decoding settled on Wuffs in `imaging`.
   No package republishes a library member; consumers import each library
   directly, and `check-library-reexports` enforces it.
3. Backend mechanisms. Done: `hostmetrics`, `gitstatus`, `localsocket`,
   `agentfiles`, `editorremote`, `cmdcapture`, `jsonl`. Measuring what each
   candidate uses from core showed `history-store` and `checkpoint` persist
   telar's own model, so they stay; `kitty-media` and `pane-render` build
   protocol values, and their cuts are listed above.
4. Proxy. Done: `h2frames`, `localca`; `eventstream` was removed with agent observation. The relay and the
   capture buffer carry telar policy, so the proxy first moves to the
   procedural model:
   - A. Ports with one production implementation become direct calls:
     lifecycle, accept loop, CONNECT authentication, TLS establishment, the
     credential gate and the observer pipeline. Done.
   - B1. The transformer pipeline goes; the one production rule (identity
     encoding for Claude inference requests) is a rewrite telar hands the
     relay.
   - B2. HTTP/1.1 head analysis reports method and target; telar classifies
     the request by dialect.
   - B3. The relay reports forwarded head and body bytes; capture happens in
     telar.
   - B4. The HTTP/1.1 connection and exchange ports become one comptime
     handler type whose methods receive the relay's neutral events.
   - B5. The same for HTTP/2: the relay reports stream facts (head, status,
     reset, goaway, body end) and telar decides phases.
   - B6. `middleware.zig` splits into HTTP header rules, which go with the
     relay, and telar's phases and protocols.
   - C. The HTTP/1.1 and HTTP/2 relays and header rules move to
     `lib/httprelay` (done); the capture buffer moves to
     `lib/exchangecapture`, generic over the owner metadata telar attaches
     (done); the bounded queue both proxy channels duplicated moves to
     `lib/dropqueue`, and the credential gate on it stays in telar (done).
   Step 4 is done.
5. The protocol's mechanism: `bytecodec` (the bounded little-endian
   encoder and decoder) and `cellcodec` (cell runs). The messages stay in
   core as telar's protocol. Done.
6. Client and GUI. Done: `urlscan`, `mdinline`, `cellglyphs`,
   `kitty_protocol`, `keyinput`, the `console` additions, `textraster`,
   `syntaxhl`, `textfield`. Measuring each candidate first changed several
   cuts; the table records what moved and what stays. From step 3,
   `pane-render` became `vtgrid` and `kitty-media` stays in the runtime
   with its mechanism moved to `imaging` and `kitty_protocol`.
7. In parallel with any of the above: the business rules listed in the
   previous section move into flows.

Each step leaves every suite green and deletes the old location in the same
commit.
