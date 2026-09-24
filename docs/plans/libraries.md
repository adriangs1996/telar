# Libraries out of the application

Target: every piece of code is one of three things.

- **State** lives in the process model: `RuntimeModel` or `ClientModel`, its
  tables and records.
- **Business rules** are flow procedures over that model, reached from
  `update`. A rule stays here even when it is pure: what an agent status
  means, which host is Claude, when a review edition may be commented.
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
| `sse` | `src/backend/proxy/{sse,Decoder,SseEvent}.zig` | std |
| `h2-framing` | `src/backend/proxy/h2/{framing,Reader,streams,Tracker,HeaderField,HeaderBlock,PeerSettings,Settings}.zig` | std |
| `local-ca` | `src/backend/proxy/{ca,Authority,AuthorityFiles,Pair,Resources,Roots,tls,Session,InterceptOptions}.zig` | std, tls |
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
| `jsonl` (done) | `agent_panes/{Stream,OutputFrame}.zig` and the JSON helpers of `agent_panes/protocol.zig` | the rest of `agent_panes` translates Codex's protocol into telar's agent threads and stays |
| `kitty-media` | `src/backend/media` (processing, budgets, PNG through wuffs) | produces `core.ImageKey`, `core.Image`, `ShmName` and the graphics limits of the protocol; waits for `wire` |
| `pane-render` | `pane/{blit,damage,text_search,Diff,Cursor,TextDump}.zig` | encodes `core.Span` and cell sizes of the protocol; waits for `wire` |
| `checkpoint` (not a library) | `src/backend/persistence` | it is telar's session format (pane kinds, providers, tab labels); its codec is `wire`'s |
| `localsocket` (done) | `transport/{LocalListener,local}.zig` (both sides) and `src/core/transport` | none; the handshake stays in the app because it speaks telar's wire |
| `editorremote` (done) | `editors/{remote,expressions,Target,Candidate}.zig`, `core/editor.zig` | the search works on its own candidates and reports an index; the runtime job keeps panes and the reply |
| `hostmetrics`, `gitstatus` (done) | `runtime/observability/{Sampler,system_metrics,darwin,Raw,Values,SystemMetricsSample}.zig`, `runtime/resources/git_probe.zig` | the probe interval and the per-workspace completion stay in the runtime |
| `imaging` (done) | `src/gui/image` decoders and box filter | PNG now decodes through Wuffs; sprites, attachments and the favicon worker stay in the GUI |
| `box-glyphs` | `src/gui/text/{Box*,Block*,block_shapes,Braille*}.zig` | they emit into `render/QuadList.zig`, which imports `native/DiagramTexture.zig`; the quad list joins `layout` without the texture |
| `markdown-spans` | `gui/widgets/{MessageSpan,MessageSpans,MessageSpanScope}.zig` | inline the URI extraction it borrows from core |
| `key-capture` | `client/input/{GenericRouter,GenericKeymap,Capture,key_support,action_routing,edit,mouse_protocol}.zig` and `frontend/input` | the keymap types become parameters |
| `screen-diff` | `frontend/presentation/{Screen,diff,screen_support,GenericInput,Parsed,pointer}.zig` | `frame.zig` stops returning `model` types |
| `kitty-render` | the model-free half of `frontend/graphics` (codec, bitmap, rasterizer, compression) | split from the renderers that read `model` |

### Larger cuts

| Library | From | Cut |
| --- | --- | --- |
| `http-relay` | `proxy/http`, `proxy/h2/{relay,connection,Observer,Transcoder}.zig` | every file tags events with `agent/types.ApiDialect` and `middleware.Phase`; the tag becomes a comptime parameter or an opaque integer |
| `capture-buffer` | `proxy/capture` | `Half` embeds a telar pane and credential; becomes an owner id plus a gate |
| `wire` | `src/core/schema` (192 files) | it reaches back into core's root 56 times for shared value types; those move down into `wire` or into `cells` |
| `syntax`, `diagram-client` | `gui/syntax`, `gui/diagrams` worker and protocol | the capture-to-role mapping and the image decode path become library dependencies |

What stays in `telar-core` after the cuts: agent manifests and providers,
plugin manifests and capabilities, proxy and editor protocol values, history
filters and fuzzy matching. It imports `wire`, `cellgrid` and `pacing` where
its own values need them and republishes none of them: every package imports
the libraries it uses by name.

## Business rules that must move into flows, not into libraries

- `src/backend/agent/tracker_support.zig` (1,514 lines, bigger than
  `Agent.zig`) coordinates observations, the aggregate and snapshot
  publication: a runtime flow living under `agent/`. It moves to
  `src/backend/runtime/`, and its import of `agent_panes/Transcript.zig`
  becomes a parameter.
- `Agent.apply{Process,Proxy,Report,Screen}`, `expire` and `reproject`
  decide what an agent status means; they become procedures of the agent
  flows over the `agents` table.
- `src/backend/runtime/attachment/media_projection.zig` decides freeze and
  adoption across every client's attachment store; it belongs to the
  `pane_graphics` flow.
- `Pane.queueGraphicsLimitResponse` builds a Kitty error reply by hand;
  that encoding belongs to `kitty-media`.
- `ClientModel` keeps flow logic inline: copy mode (about 150 lines),
  workspace list reconciliation, agent snapshot reconciliation,
  configuration adoption, pane retirement, tab detachment. They move to
  their flow files.
- Provider policy in the proxy (`proxy/provider/*`: which hosts are Claude or
  OpenAI, which routes are inference, what an Anthropic turn end looks like)
  stays in the app as business rules; the relay libraries receive it as data.

## Duplicates and misplacements found

- Two PNG decoders (resolved): `src/gui/image/png.zig` was a hand-written
  decoder over `std.compress.flate`; `imaging.png` now reads only the IHDR
  to enforce limits and hands decoding to Wuffs, the decoder the runtime
  already installs into the emulator from `src/backend/media/png.zig`.
- Three SQLite bindings (listed above).
- `src/backend/proxy/Channel.zig` and `src/backend/proxy/capture/Channel.zig`
  are the same credential-gated bounded queue over two payload types; one
  generic queue.
- Two different types named `SessionTitle` (`history/`, `agent/`); rename the
  history one.
- `src/core/select.zig` holds two unrelated features (click granularity for
  the client, history filters for the runtime).
- `src/model/types` holds 87 files averaging 13 lines; each folds into the
  flow or table that owns it.
- `src/gui/experiments` is not reached by any build step.

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
   protocol values and move after `wire`.
4. Proxy. Done: `eventstream`, `h2frames`, `localca`. The relay and the
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
     `lib/httprelay` (done); the capture buffer, keyed by an owner id, and
     one credential-gated queue generic over its payload move to `lib/`.
   B1 to B6 are done.
5. `wire`, which touches both processes and every message.
6. Client and GUI: `key-capture`, `screen-diff`, `kitty-render`, `image`,
   `box-glyphs`, `markdown-spans`, `syntax`, `diagram-client`.
7. In parallel with any of the above: the business rules listed in the
   previous section move into flows.

Each step leaves every suite green and deletes the old location in the same
commit.
