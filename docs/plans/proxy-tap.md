# ProxyTLS tap and agent command persistence — handoff

Status: P1-P3 complete on 2026-09-03; P4-P7 not started. This document is the
handoff for the remaining implementation. Every file:line below was verified
against commit `46db649` (`main`) on that date; symbols outlive line numbers,
so search for the symbol when a line has moved.

## Environment

- Work in the worktree `/Users/adriangonzalez/sandbox/telar-tap`, branch
  `proxy-tap`, based on `main` at `46db649`. Do not create worktrees under
  `.claude/worktrees/`: the path is long enough that the Unix-socket tests
  fail with `NameTooLong` (`sun_path` is 104 bytes on macOS).
- `zig build test` is green on that base (3089 tests). Zig 0.16.0.
- `libbrotli` 1.2.0 is installed at `/opt/homebrew/opt/brotli`
  (`include/brotli/decode.h`, `lib/libbrotlidec.dylib`). Zig std ships
  `flate` (gzip, deflate, zlib) and `zstd`; it does not ship brotli.
- Read `docs/engineering-invariants.md` before touching the proxy, history,
  Lua or plugin code. The sections that bind this work are "Observation",
  "History and proxy", "Lua configuration", "Lua plugins" and "Local
  authority and storage".
- Every phase ends with `zig fmt src`, `zig build test`, a flow doc under
  `docs/flows/` when it crosses the socket or three capability owners, and one
  commit per phase with its status written back into this file.

## Decisions already made (do not reopen)

1. **Two sources for agent commands.** Native harness hooks
   (`PreToolUse`/`PostToolUse`) are the authoritative source. A Lua tap over
   ProxyTLS is the second, user-programmable source. Native agent detection
   (`Tracker`, SSE turn detection) stays native and untouched; Lua only adds
   evidence and persistence.
2. **The tap hands Lua whole exchanges as raw bytes.** Telar does not parse
   JSON or SSE for the tap. Telar only de-frames (HTTP/1.1 chunked, HTTP/2
   DATA reassembly), decompresses, and delivers `request_head`,
   `request_body`, `response_head`, `response_body` per exchange when the
   exchange finishes. The Lua script classifies. Use cases the design must
   serve: an agent detector, an agent command persister, a browser traffic
   analyser for a pentest.
3. **Brotli is decoded natively by linking `libbrotlidec`**, mirroring how
   `nghttp2` is linked. Do not strip `br` from `Accept-Encoding`.
4. **Full trust, one capability.** The tap is `proxy.tap`, granted per plugin
   digest with the existing `telar plugin trust` flow. Lua sees unredacted
   headers and bodies, including `authorization`. Docs must say plainly that
   a plugin with `proxy.tap` is full-trust code.
5. **Redaction only at persistence, on by default.** The
   `history.record_command` effect runs the `core.history_filter` secret
   rules before writing unless the effect sets `redact = false` explicitly.
   Reason: the `command` table is FTS-indexed, printed by `telar history`
   and read by other agents; what Lua saw in memory dies with the worker,
   what lands in SQLite does not.
6. **Allocation is allowed for captures**, on the observation budget, with
   byte quotas per exchange and a global quota, a `truncated` flag per part,
   and single-owner buffers freed by the consumer. Relay never blocks on
   capture: when a quota is exhausted, capture stops and traffic continues.
7. **The Lua worker runs on the runtime side** (it must survive the client),
   as a long-lived child process per trusted plugin, supervised like the
   engine child (`src/backend/engine/service.zig`).
8. **Wildcard `intercept_hosts`** (`*.example.com`, and bare `*`) and an
   easy, reversible `telar proxy trust install|uninstall|status` for the CA
   are in scope, as the last phases.

## Verified code map

### Proxy (`src/backend/proxy/`)

- **Identity per CONNECT**: `tunnel/exchange.zig:25` `Exchange { io,
  pipeline, telemetry, credential, dialect, connection_id, protocol,
  status_code }`, built in `tunnel/root.zig:83-91`. `credential.token` is
  secret and is `secureZero`ed everywhere; never copy it into a capture.
  The CONNECT host (`target.host`, `tunnel/root.zig:82`) and the request
  path are **not retained** today; the tap must plumb host from
  `tunnel/root.zig` and route from head parsing.
- **Observation events**: `middleware.zig:63` `Event` is a pure value
  (credential, dialect, phase, protocol, connection_id, stream_id,
  status_code, observed_at_ms). Published synchronously on the tunnel task
  by `Exchange.publishStatus` (`tunnel/exchange.zig:58`) through
  `middleware.Pipeline` (max 8 observers, immutable after start).
- **Queue**: `observation_queue.zig` `Channel`, `capacity = 256`, CAS
  reserve then `Io.Queue.put(..., 0)` non-blocking, drops counted. Consumed
  by `service/observations.zig` → `service/service.zig:161 receive` →
  runtime `event_sources.zig:79 receiveProxyObservation` →
  `runtime/entrypoints/events/proxy_observation.zig:66 handle`. Mirror this
  for a second, byte-budgeted capture queue. Do not widen `middleware.Event`
  with slices.
- **HTTP/1.1 bodies**: `http/body.zig:37 relay`. `relayChunked` (:98)
  already strips chunk framing from `Fragment.payload`; trailers are never
  surfaced. Fragments borrow a 16 KiB stack buffer valid only during
  `observe`; copy. Sinks: `tunnel/http1.zig:84 RequestBodyObserver.observe`
  and `:108 ResponseBodyObserver.observe`. Request body and response run
  **concurrently** in one exchange (`http/connection.zig:56-62` `Select`),
  so request and response captures must be owned per direction.
- **HTTP/1.1 heads**: `http/root.zig:80 relayHead` and `:108
  relayHeadTransformed` hold the full head bytes in a stack buffer
  (`max_head_bytes = 32 KiB`) and return metadata only (`head.zig:25 Head`).
  Add an optional capture sink to `HeadTransform`/`MessageRoute` to copy the
  original head bytes before they are dropped.
- **HTTP/2**: two code paths in `h2/relay.zig`. Observation mode `relay()`
  (:1117) with `Observer`; transform mode `relayTransformed()` (:1164) with
  `Transcoder`. Mode is chosen in `tunnel/h2.zig:213 shouldTransform`:
  transform only for custom transformers or the Claude request direction.
  In observation mode the header block is inflated field by field in
  `Observer.decodeBlock` (:424) and only `Decoded` flags are kept; extend
  that loop to emit fields to the capture sink. In transform mode the
  equivalent is `Transcoder.decodeHeaders` (:926) and `finishHeaderBlock`
  (:815-924), where a full `middleware.Headers` exists. DATA payloads reach
  the sink through `Observer.observePayload` (:226) after `dataBodyFragment`
  (:384) strips padding; there is no cross-frame accumulation anywhere.
  Request and response directions run concurrently
  (`h2/connection.zig:50`), each with its own stack `EventObserver`
  (`tunnel/h2.zig:171-187`). Stream end is signalled by `Event.lifecycle`
  with `response_finished`/`request_failed` and `Event.request_finished`
  (`h2/relay.zig:279-372`). `Observer` and `Transcoder` are already ~500 KiB
  stack structs: do not add inline capture buffers to them.
- **Per-stream slot idiom to copy**: `provider/request_body.zig:103
  Streams` (128 fixed slots keyed by stream id, `start/feed/finish/discard`,
  fail closed on capacity) and `provider/root.zig:90 ResponseStreams` (heap
  object per stream, freed in `finish`).
- **Heads and sensitivity**: `middleware.zig:230 Headers` (256 fields,
  128 KiB) with `HeaderField.sensitive` set by `isSensitiveName` (:466:
  authorization, proxy-authorization, cookie, set-cookie, x-api-key,
  api-key). Header values are currently never copied to the observation
  queue by design; the tap changes that under `proxy.tap` and
  `docs/proxy-tls.md` must be rewritten accordingly.
- **Content encoding today**: `provider/claude_transport.zig:16` forces
  `accept-encoding: identity` only for Claude `POST /v1/messages`, installed
  at `service/configuration.zig:27`. Everything else may arrive gzip, br or
  zstd; `middleware.isIdentityContentEncoding` (:46) and
  `head.hasObservableSseBody` (:103) are how the current code refuses to
  inspect encoded bodies.
- **Allocation**: no arena, no per-connection allocator. The only gpa use in
  a tunnel is `ResponseStreams.create/finish`. Every wire buffer is
  `secureZero`ed on release; follow that.
- **Concurrency model**: `std.Io` tasks, one per CONNECT
  (`service/service.zig:261`, `max_connections = 64`). No thread pool. The
  "observation worker" is the runtime loop's `Select` branch.
- **Interception policy**: `interception_policy.zig:18 Policy.init` sorts
  and dedupes exact hostnames; `:45 contains` is a binary search, exact and
  case-insensitive. Tests at `:90-98` assert that suffixes do not match.
  Config-side rejection of `*` is `src/frontend/config/proxy.zig:108
  validHostname` (test at `:161`).
- **CA**: `ca.zig` — CA valid 3650 days (:18), leaf 30 days (:19), CN
  `telar local CA` (:23), P-256. Paths are built by the CLI at
  `src/cli/server.zig:208-210` (`ca-key.pem`, `ca-cert.pem`,
  `ca-bundle.pem`) under `runtime.proxy.ca_dir` or
  `$XDG_DATA_HOME/telar/proxy`. Atomic writer `writeSecure` (:207).
- **build.zig nghttp2 mirror points** for `brotlidec`: option at `:29-40`,
  backend `:72-74`, bench backend `:161-164`, `proxyModule` helper
  `:399-425` (used at `:432`, `:448`, prefix at `:337/:554`), test module
  `:575-577`. Missing the test module breaks `zig build test` linking.
- **Tests**: `http/test_support.zig FakeSession` (byte-exact wire assertions
  plus observed payload), the "split at every offset" idiom
  (`provider/root.zig:202`, `h2/relay.zig:1460`), `Capture` observers with
  `expectPhases` (`tunnel/http1.zig:312-360`, `tunnel/h2.zig:243-297`), and
  the real-socket end-to-end template
  `service/service_test.zig:145` with `listenTestOrigin` (:132). No test
  drives a real TLS-intercepted HTTP exchange today; interception coverage
  is at the `FakeSession` layer.

### Plugins and Lua

- **Already in core, reuse as is**: `src/core/plugin.zig` — `Manifest`,
  `parseManifest` (:114), `Capability` enum (:15, canonical names
  `workspace.read`, `workspace.write`, `process.spawn`, `network`,
  `clipboard.read`, `clipboard.write`, `notifications`, `history.read`,
  `runtime.control`), `Grant`, `TrustStore` (:199, `max_grants = 64`),
  `stableId` (:301). Add `proxy.tap` and `history.write` here.
- **CLI, unchanged**: `src/cli/plugin.zig` `inspect|install|trust`,
  `trustPath` (:49) `$XDG_CONFIG_HOME/telar/trust.json`, `installBase`
  (:127) `$XDG_DATA_HOME/telar/plugins/<id>/<sha256>/`, atomic
  `writeStore` (:177).
- **Client worker today** (`src/frontend/plugins/`): one-shot process
  `telar plugin-worker` (`src/cli/parser.zig:283-297`, nine positional
  argv), spawned by `root.zig:225-299 executeWorker` with a private 0700
  snapshot copy rehashed before execution (`installPackage` :435-505,
  `digestPackage` :360-425), `cwd = "/"`, empty environment, 2 s timeout,
  stdout capped at `protocol.max_bytes`. Protocol `protocol.zig` is
  `u8 count` then `u8 tag` + payload, strict trailing-bytes check, encodable
  effects only. Broker `Registry` (:38-195): `authorize` (:133),
  `authorizeBatch` (:147) re-checks stable id and exact digest. Effect →
  capability table at `:159-183`. Single-flight, correlated by execution id
  and configuration generation
  (`src/frontend/client/application/input/plugin_action.zig`).
- **VM**: `src/frontend/config/vm.zig` (149 lines) is self-contained apart
  from `model.Limits`: metered allocator, instruction hook, deadline,
  `resetBudget`. Sandbox environment is
  `src/frontend/config/generation.zig:439-460 openEnvironment` (base,
  coroutine, math, string, table, utf8; `collectgarbage`, `dofile`,
  `getmetatable`, `load`, `loadfile`, `print`, `rawset`, `setmetatable`
  removed). `generation.zig` itself is 3658 lines and client-shaped; do
  not lift it. Lua is vendored (`vendor/lua-5.5.1`), built by `addLua`
  (`build.zig:785+`) as module `lua-api`, imported only by `frontend`
  (`build.zig:87`). `core` has no libc and no `lua-api`; `backend` links
  libc (`build.zig:66`).
- **Runtime already runs Lua disposably**: `src/cli/server.zig:114-176`
  loads a full `frontend.config.Generation` in the server process to read
  `runtime.*`, converts it to typed `backend.runtime.Options`, and drops it.
  Plugin specs (`config.plugins`) are not forwarded to the runtime today.

### Runtime

- Event loop: `std.Io.Select(RuntimeEvent)`, `src/backend/runtime/instance.zig:120-147`;
  event union `runtime/event.zig:29-49` with budget classification at
  `:63-86` (put new events under `observation`). Arming is
  `Sources.select.concurrent(.tag, fn, args)` in `event_sources.zig`,
  initial arming in `InitialSources.schedule` (:127-144).
- Long-lived actor pattern: engine — `resources/engine.zig:17` starts
  `engine.Service.run` with `io.concurrent`; the actor owns one child
  process (`engine/session.zig:48 std.process.spawn`), bounded request and
  response rings, deadline per exchange, idle kill, and a documented
  failure policy (`docs/flows/engine.md`).
- Proxy observation entrypoint to extend or clone:
  `runtime/entrypoints/events/proxy_observation.zig` (`Resources` :16-20,
  `handle` :66 resolves the pane by credential and drops stale generations),
  constructed at `runtime/application/event_dispatcher/agent.zig:199-205`.

### History

- `src/backend/history/service.zig:206 recordCommand(service, io,
  CommandRecord) bool` applies `filters.shouldRecord` then
  `request_factory.commandFinished` then `submit`. Sequential worker
  `worker.zig:74 run`, dispatch `:126 execute` (exhaustive switch over
  `model.Request`; a new variant must be handled there). Started with
  `io.concurrent` at `runtime/resources/history.zig:17`.
- `model.zig:141 CommandFinished` is one aligned allocation holding the
  struct plus its four byte slices (`request_factory.zig:130-134`,
  `model.zig:161-163`); adding an owned string means updating both length
  computations.
- `author: schema.HistoryAuthor { human = 0, agent = 1 }`
  (`src/core/schema/types.zig:255`). There is **no `provider` column**
  anywhere; the atuin plan's mention of one was not implemented.
- `session_id` is a foreign key to `session(id)` with `foreign_keys = ON`
  (`persistence/sqlite.zig:14`). A record from the tap must use the pane's
  live history session or synthesize one the way `importBatch` does
  (`model.zig:499-549`, `INSERT OR IGNORE`).
- Schema: version 4 (`sqlite.zig:21`), migration idiom `ensureColumn`
  (`:171-176`, impl `:896`). Insert SQL `:134` and `:96`, binder `:391-415`.
- Filters: `src/core/history_filter.zig` `Filters.shouldRecord` (:66),
  secret rules `:97-114`, `looksLikeSecret` (:119). Config keys
  `command_filters`, `cwd_filters`, `secrets_filter` in
  `src/frontend/config/history.zig`.
- The only production caller of `recordCommand` is
  `src/backend/pane/root.zig:1795` (`CaptureContext.emit`), which flips one
  command to `.agent` from a per-pane `injected_submissions` counter.

### Hooks

- `src/cli/integration.zig:14-15`: `claude_events = { SessionStart,
  UserPromptSubmit, Stop, Notification, SessionEnd }`, `codex_events = {
  SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse, Stop,
  Interrupt, SessionEnd }`. `src/cli/hook.zig:243` maps Claude
  `PreToolUse` to `null`; Codex `PostToolUse` means `working` only (:256).
  Pi's extension already emits `tool_execution_start` (test at :221, mapped
  to `null`). Reports travel as `report_agent` requests
  (`runtime/entrypoints/requests/report_agent.zig`).

### Config chain

`src/frontend/config/proxy.zig:16-20` allowed fields `{ enabled, ca_dir,
intercept_hosts }` → `RuntimeSnapshot` (`config/model.zig:240-259`) →
`src/cli/server.zig:129 applyConfig`, `:176 prepareRuntimeStorage`
(`proxy_options` at `:207-212`), `:216 runtimeInitialization` →
`backend/runtime/config.zig:43 Options.proxy` → `resources/proxy.zig:57` →
`proxy/root.zig:85 Proxy.create` → `service/interception.zig:41` →
`interception_policy.zig:18`. `runtime` allowed keys are listed at
`generation.zig:578-584`; a new subtree needs a `config/<name>.zig` with
the `parse(state, runtime, diagnostic)` signature of `history.zig:8`.
There is no `runtime.plugins`; plugins are top-level `config.plugins`
(`config/plugins.zig`, fields `path`, `enabled`).

## Phases

Order: P1 → P2 → P3, then P4 (independent of P2/P3, can run in parallel
with them), then P5, P6, P7.

### P1. Native exchange capture in the proxy

Status: complete on 2026-09-03. `zig fmt src`, `zig build check`, and
`zig build test` pass. The capture flow is documented in
`docs/flows/proxy-capture.md`.

Goal: for every intercepted exchange, when `runtime.proxy.capture.enabled`,
produce one `CapturedExchange` and hand it to the runtime without touching
traffic.

- New `src/backend/proxy/capture/` capability (`root.zig`, `buffer.zig`,
  `table.zig`, `queue.zig`, `decode.zig`).
  - `Part = enum { request_head, request_body, response_head, response_body }`.
  - `Buffer`: gpa-owned, grows to `max_part_bytes`, `truncated: bool`,
    `secureZero` on free.
  - `Quota`: `per_part_bytes` (default 4 MiB), `per_exchange_bytes`
    (default 8 MiB), `global_bytes` (default 64 MiB, atomic counter). When
    the global quota is exhausted, new exchanges are not captured and
    `capture_skipped` is counted; existing captures keep their reservation.
  - Because request and response directions run on different tasks in both
    protocols, capture **halves**: `RequestHalf` owned by the request task,
    `ResponseHalf` owned by the response task. Each half is published on
    its own when its direction finishes (or fails). The runtime-side joiner
    pairs halves by `(connection_id, stream_id)` and emits one exchange when
    both arrived, or a partial one after `join_timeout_ms` (default 30 s)
    with the missing half marked absent. This keeps relay lock-free.
  - Keys and metadata to record: pane id and generation (never the token),
    dialect, protocol, connection id, stream id, host (plumbed from
    `tunnel/root.zig`), method and target (from head parsing), status code,
    `started_at_ms`, `finished_at_ms`, `content-encoding` of each body as
    seen on the wire, outcome (`finished`, `failed`, `reset`).
- Hook points:
  - HTTP/1.1 heads: add an optional `capture: ?*capture.HeadSink` to
    `http.HeadTransform` / `MessageRoute`; copy the original head bytes in
    `relayHead` and `relayHeadTransformed` before returning.
  - HTTP/1.1 bodies: append `fragment.payload` in `RequestBodyObserver` and
    `ResponseBodyObserver`; publish the half in `finishRequest` /
    `publishResponse` / `publishFailure` (`tunnel/http1.zig`).
  - HTTP/2: add `Event.request_headers` / `Event.response_headers`
    carrying a borrowed field list emitted from `Observer.decodeBlock`
    (observation mode) and `Transcoder.decodeHeaders` (transform mode);
    append DATA in `EventObserver.emit`; publish halves on
    `request_finished`, `response_finished`, `request_failed`, RST and
    GOAWAY. Use a 128-slot table keyed by stream id like
    `provider.RequestStreams`; heap objects like `ResponseStreams`.
  - Capture must run regardless of dialect (pentest hosts are `.unknown`).
    Today `tunnel/h2.zig:56-57` passes `null` observers for non-Claude
    dialects; capture observers are separate and always installed when
    enabled.
- Queue: `capture/queue.zig` mirroring `observation_queue.zig` but with
  pointer ownership transfer (`Io.Queue(*Half)`), count cap (256) and byte
  accounting; non-blocking put; a dropped half is freed by the publisher.
  Credential gate at publish and receive, same as today.
- Decoding happens on the consumer side (runtime observation path), never
  in the relay: `decode.zig` handles `gzip`, `deflate`, `zstd` via std and
  `br` via `libbrotlidec` (C import in `decode.zig` only). Cap decompressed
  output at `max_part_bytes`; on overflow keep the prefix and set
  `truncated`. Unknown or failed encodings deliver the raw bytes with
  `decoded = false`. Chained encodings: apply in reverse order, bounded to
  two codings.
- Runtime side: `runtime/entrypoints/events/proxy_capture.zig` with a new
  `RuntimeEvent.proxy_capture` (observation budget), the joiner, and a
  `CaptureSink` port that P2 implements. Until P2 lands, the sink is a
  metrics-only stub. Add the new resource rows to `docs/capabilities.md`.
- Config: `runtime.proxy.capture = { enabled = false, max_part_bytes,
  max_exchange_bytes, max_total_bytes, join_timeout_ms }` through the whole
  chain listed above. Keep `capture` off by default.
- build.zig: `brotli` option and `brotlidec` link in the five mirror
  points. Add a CI note to `.github/` if the workflow installs `nghttp2`.
- Metrics: `capture_started`, `capture_truncated`, `capture_skipped_quota`,
  `capture_dropped_queue`, `capture_decode_failed` in `proxy/metrics.zig`
  and the snapshot.
- Tests: `FakeSession` HTTP/1.1 request with chunked body and response
  with `content-length`, split at every offset, asserting byte-exact
  forwarding plus captured parts; HTTP/2 two interleaved streams with
  padded DATA and CONTINUATION; quota exhaustion mid-body sets `truncated`
  and keeps relaying; queue saturation drops and frees; brotli, gzip and
  zstd round trips with an output cap; joiner pairs and times out; a
  `service_test.zig`-style run proving capture is inert when disabled.
- Docs: `docs/proxy-tls.md` new section "Exchange capture" and rewrite of
  the sentence "Header values are not persisted or copied to the
  observation queue"; `docs/configuration.md` new keys; flow doc
  `docs/flows/proxy-capture.md`.

### P2. Runtime-side Lua worker

Status: complete on 2026-09-03. `zig fmt src`, `zig build check`, and
`zig build test` pass. The worker flow is documented in
`docs/flows/proxy-tap.md`.

Goal: a trusted plugin with `proxy.tap` receives each captured exchange in
a long-lived, isolated Lua process supervised by the runtime, and returns a
bounded effect batch.

- New build module `telar-lua` (`src/lua/root.zig`) holding what both
  processes need: move `src/frontend/config/vm.zig` there (make `Limits` a
  parameter of the module rather than importing `config/model.zig`), and a
  shared `sandbox.zig` extracted from `generation.zig:439-460
  openEnvironment`. `frontend` and `backend` import `telar-lua`; `core`
  stays free of Lua and libc. Update `docs/capabilities.md` package table.
- New backend capability `src/backend/plugins/` (`root.zig`, `service.zig`
  actor, `session.zig` child, `protocol.zig`, `host.zig` Lua host used by
  the worker process, `effects.zig` runtime effect union).
  - Worker process: new internal subcommand `telar tap-worker <entry>`
    (`src/cli/parser.zig` next to `plugin-worker`, `src/main.zig` dispatch).
    Spawned per enabled plugin that declares and is granted `proxy.tap`,
    from a private 0700 snapshot copy rehashed before spawn (reuse
    `installPackage`/`digestPackage`; move them to `src/core/plugin/` since
    they only depend on frontend through `PluginSpec`). `cwd = "/"`, empty
    environment, stdin/stdout pipes, stderr capped at 4 KiB and surfaced as
    a diagnostic.
  - Protocol over stdin/stdout, length-prefixed frames, both directions.
    Runtime → worker: `exchange` frame with a monotonic event id, the
    plugin generation, metadata, and the four parts (decoded bodies). Worker
    → runtime: `effects` frame echoing the event id, `u8 count` then tagged
    effects with the strict trailing check of `plugins/protocol.zig`.
    Frame cap = `max_exchange_bytes` + 64 KiB.
  - Limits enforced outside the VM: memory (default 64 MiB, `Vm` meter),
    instructions and deadline per event (defaults 5 M and 200 ms,
    `resetBudget` per event), per-worker queue depth (64 exchanges, drop
    oldest with a counter), restart budget (5 restarts per 10 minutes, then
    disabled until config reload, with a notification), kill with
    descendants on runtime shutdown without waiting forever (engine
    pattern).
  - Lua host (`host.zig`): loads the entry with the shared sandbox, expects
    it to return a table with `on_exchange(exchange)`; `require` only
    returns `telar` plus local modules inside the package dir. `exchange`
    is a read-only table: `id`, `pane`, `host`, `protocol`, `dialect`,
    `method`, `target`, `status`, `outcome`, `started_at_ms`,
    `finished_at_ms`, `request = { head = { fields = { {name, value}...},
    raw = "..." }, body = "...", body_truncated, body_encoding, body_decoded
    }`, `response = { ... same ... }`. Bodies are Lua strings; no userdata.
  - `telar` module for the worker (`src/backend/plugins/bootstrap.lua`):
    `telar.effect.history.record_command{ command, cwd, provider, session,
    exit_code, started_at_ms, duration_ms, redact }`,
    `telar.effect.agent_evidence{ pane, state = "working"|"ready"|"blocked",
    confidence = "low"|"medium" }`, `telar.effect.notification{...}`
    (reuse `schema.encodeShowNotification` validation), and native helpers
    `telar.redact.secrets(text)` (binds `core.history_filter` rules) and
    `telar.json.decode(text)` (bounded `std.json` parse, depth 64; the
    script asked for it, telar does not call it for the tap itself).
  - Runtime integration: `resources/plugins.zig` starting the actor like
    `resources/engine.zig`; `RuntimeEvent.plugin_effects` (observation);
    `entrypoints/events/plugin_effects.zig` validates the batch against the
    trust store (plugin id, exact digest, `proxy.tap` for receiving,
    `history.write` for `record_command`, `notifications` for
    notifications), then applies each effect through existing runtime
    commands. A batch from a plugin generation that a config reload
    replaced is consumed without applying.
  - Runtime needs plugin specs and the trust store: extend
    `src/cli/server.zig applyConfig` to forward `config.plugins` and load
    `trust.json` the way `src/cli/client.zig:114-131` does. Config reload
    on the runtime side does not exist today; document that tap plugins
    are loaded at runtime start until a runtime reload exists.
- Tests: protocol round trip and strict trailing bytes; sandbox has no
  `io`/`os`/`package`; per-event budget exceeded returns an error frame and
  the worker survives; queue overflow drops with a count; restart budget
  disables the plugin; digest mismatch after copy refuses spawn; effect
  authorization refuses undeclared and ungranted capabilities; shutdown
  kills the child; a fake worker written as a shell script proves the
  runtime side end to end (engine tests do this with `session.zig`).
- Docs: `docs/plugins.md` gains an "Exchange listeners" section and the
  full-trust statement for `proxy.tap`; `docs/flows/proxy-tap.md`;
  invariants: add "Exchange listeners receive whole exchanges only after
  the exchange finished; relay never waits on a listener."

### P3. History effect and schema

Status: complete on 2026-09-03. `zig fmt src`, `zig build check`, and
`zig build test` pass. Agent-origin persistence is documented in
`docs/flows/agent-command-history.md`.

- Schema v5: `command.origin INTEGER NOT NULL DEFAULT 0` (0 pane, 1 hook,
  2 plugin), `command.provider TEXT NULL`, `command.tool_call_id TEXT NULL`
  with a unique partial index on `(session_id, tool_call_id)` for
  dedupe. Update insert/import SQL, binders, `CommandFinished` allocation
  math, query column lists, the FTS trigger set if it enumerates columns,
  and `telar history list` output (show provider dimly for agent rows).
- New `history.Service.recordAgentCommand(io, AgentCommandRecord) bool`
  that resolves the pane's live session (or synthesizes one with
  `INSERT OR IGNORE` as `importBatch` does), sets `author = .agent`,
  `origin`, and applies redaction by default (decision 5). Keep
  `shouldRecord` semantics but do not apply the leading-space rule to agent
  commands.
- Wire: no client change needed for writing. `query_history` gains no new
  filter in this phase; `--author agent` already selects these rows.
- Tests: migration on a v4 database, dedupe by `tool_call_id`, redaction
  default and opt-out, session synthesis.

### P4. Native hooks for tool calls

- `src/cli/integration.zig`: add `PreToolUse` and `PostToolUse` to
  `claude_events`; Codex already installs `PostToolUse`, add `PreToolUse`.
  Pi: map `tool_execution_start`/`tool_execution_end` in the extension.
- `src/cli/hook.zig`: parse `tool_name`, `tool_input` (Claude Code `Bash`
  → `command`; Codex `exec_command`/`shell` → `cmd`/`command`), `cwd`,
  `session_id`, and the tool call id when the payload carries one. Keep
  the subagent filter. Verify the exact payload field names against the
  installed harness versions before relying on them; do not assume.
- New request `report_agent_command` in `core.schema` (message id, bounded
  encoder/decoder, corpus and fingerprint bump in
  `src/core/schema_contract_test.zig`), a request entrypoint next to
  `report_agent.zig`, and a command handler that calls
  `history.Service.recordAgentCommand` with `origin = hook`. `PreToolUse`
  opens the row (status running), `PostToolUse` closes it with the result;
  a `PostToolUse` without a matching open row inserts a complete one.
- Tool-name to command-field mapping is manifest data: add an optional
  `command_tools = { { tool = "Bash", field = "command" } }` to
  `core.agent_manifest` so a new harness needs no code.
- Tests: hook mapping per harness, schema corpus, dedupe with a later
  plugin record carrying the same `tool_call_id`, and
  `docs/flows/agent-hooks.md` update.

### P5. Wildcard intercept hosts

- `src/frontend/config/proxy.zig validHostname`: accept a leading `*.`
  label and the bare `*`; keep rejecting `*` anywhere else and partial
  labels (`*foo.com`).
- `interception_policy.zig Policy`: keep the exact binary search; add a
  sorted suffix list matched by comparing reversed labels, and an
  `intercept_all` flag for `*`. Every CONNECT still requires a live pane
  credential.
- The top-bar badge (`docs/flows/proxy-status.md`,
  `docs/flows/configurable-bars.md`) shows a distinct state when `*` or a
  suffix rule is active; carry a `scope` enum in the proxy status message
  (schema bump).
- Docs: `docs/configuration.md:530-535` ("Wildcards are rejected") and
  `docs/proxy-tls.md` allowlist paragraph.

### P6. CA trust install

- New CLI family `telar proxy trust install|uninstall|status` modelled on
  `telar integration` (`src/cli/integration.zig:47 run`, `parser.zig:1219
  IntegrationAction`). Local file work only; no runtime socket.
- macOS: login keychain, no sudo:
  `security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db <cert>`;
  uninstall by SHA-1 fingerprint with `security delete-certificate -Z`.
  Record the installed fingerprint and keychain path in
  `<proxy_dir>/trust-install.json` (0600) so uninstall removes exactly
  that certificate. Linux: `update-ca-certificates` or `trust anchor`
  behind a flag, printing the exact command before running it. Firefox
  keeps its own store: print instructions, do not automate.
- Safety: install a **separate CA** for system trust (`ca-system-*.pem`)
  with 30-day validity and rotation on `telar server` start, so a stolen
  key expires; the runtime mints leaves from whichever CA is installed.
  The interception badge stays visible while a system-trusted CA is
  installed even if the proxy is off (status query reads the record).
- Docs: rewrite `docs/proxy-tls.md:48` and `:242-246` ("System trust
  remains unchanged") and the invariant at
  `docs/engineering-invariants.md:221-222` to describe the explicit,
  reversible action.

### P7. Shipped example plugin and docs

- `examples/plugins/agent-commands/` with `plugin.json` declaring
  `proxy.tap`, `history.write`, `notifications`, and a Lua entry that
  detects Anthropic `tool_use` blocks and OpenAI `function_call` items in
  response bodies (accumulating `input_json_delta` / `arguments.delta` in
  Lua with `telar.json.decode`), maps `Bash.command`, `shell.command`,
  `exec_command.cmd` and records them. This is the reference for the
  "user classifies" model and doubles as an integration test fixture.
- `docs/plugins.md`, `docs/proxy-tls.md`, `docs/configuration.md`,
  `docs/capabilities.md`, `docs/flows/README.md` rows, and this file's
  status per phase.

## Open items the implementer must verify, not assume

- Exact hook payload field names for tool call ids in the installed
  Claude Code, Codex and Pi versions (P4).
- Whether `nghttp2_hd_inflate_hd2` field values in `Observer.decodeBlock`
  remain valid after the next call; copy them immediately (P1).
- The `Io.Queue` semantics for pointer elements and closure draining, so a
  closed capture queue frees every buffered half (P1).
- Stack size of the proxy `Io` tasks before adding any struct to the relay
  path; the H2 observer is already ~500 KiB (P1).
- macOS `security` flag behaviour on the current OS version, including the
  trust-settings GUI prompt (P6).
