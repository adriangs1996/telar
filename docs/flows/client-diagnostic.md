# Client diagnostic state

The client diagnostic is one disposable, bounded banner shared by Lua actions,
configuration reloads and plugin execution. Producers decide the message and
whether a separate notification is useful. One application handler owns every
state transition.

## Boundary

```text
Lua invocation or validation failure
        |
LuaActionHandler ------------------------+
                                         |
configuration worker rejection           |
        |                                |
config_reloads -> client_diagnostics ----+--> ClientDiagnosticHandler
                                         |             |
plugin resolution or completion failure  |    validate primary value
        |                                |             |
plugin_actions -> client_diagnostics ----+      optional safe fallback
                                                       |
                                     ClientModel.replaceDiagnostic / clearDiagnostic
                                                       |
                                           Version.diagnostic
                                                       |
                                      client_events -> Presenter

committed config or plugin diagnostic -> optional notification publication
```

`LuaActionHandler` composes `ClientDiagnosticHandler` directly because both
belong to the application layer. Concrete configuration and plugin adapters
enter through `client_diagnostics`, which only constructs the same handler and
formats fixed-capacity values. No producer mutates diagnostic model state
directly.

Notification publication is a separate use case. Configuration and plugin
failures first commit the banner and then let `notifications.publishDiagnostic`
read that committed value. Lua failures intentionally publish only the banner.
A notification failure cannot roll back diagnostic state.

## Validation and revisions

`config.Diagnostic` stores at most 512 bytes. `ClientDiagnosticHandler.replace`
passes the primary value to `ClientModel`, which validates its declared length
and UTF-8 before mutation. A producer may supply one explicit bounded fallback
for malformed external text. The handler uses it only after primary validation
fails; a malformed fallback returns `InvalidClientDiagnostic` and preserves the
previous value.

Equal text is a no-op. Empty text and `clear` remove a visible diagnostic once.
Each actual replacement or removal advances `Version.diagnostic` exactly once;
validation failure and repeated state advance nothing. `formatted` writes into
the fixed diagnostic buffer and falls back to the existing static
`configuration error` text if formatting exceeds it.

Successful Lua evaluation, accepted configuration adoption and authorized
plugin effect application clear an older banner through the same handler. The
diagnostic handler never requests a frame. `client_events` publishes the model
version and `Presenter` folds a real diagnostic revision into its paced frame.

## Bounds and proof

The transition allocates nothing, copies only fixed-capacity values and runs
independently of notification timers or runtime transport.

- `src/frontend/client/model.zig` proves UTF-8 and length validation, equality,
  clear behavior and isolated diagnostic revisions.
- `src/frontend/client/application/client_diagnostic.zig` proves valid commit,
  explicit fallback, preservation after two malformed values and idempotent
  clear.
- `src/frontend/client/application/lua_action.zig` proves failure fallback and
  clear-before-effects ordering through the shared handler.
- `src/frontend/client/client_test.zig` proves configuration, Lua and plugin
  outcomes plus presenter observation on a real client.
