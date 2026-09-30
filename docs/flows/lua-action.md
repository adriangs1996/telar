# Lua action

This flow starts after the native input router matches a configured Lua
callback or expression. The callback VM may return semantic client effects or
semantic input. It never returns terminal bytes or mutates client objects.

## End-to-end path

```text
configured binding
      |
Router.routeEvent -> GuiAdapter.applyInputDecision / HeadlessClient.decide
      |
actions.executeAction -> lua_action.executeLuaAction
      |
lua_action.evaluateLuaAction
      |
plugin_action.callbackContext
      |
client-owned Generation.invokeCallback / invokeExpression
      |
      +-- callback --> EffectBatch --> lua_actions.validateBatch
      |                                  |
      |                         lua_action.applyLuaEffect
      |                         -> executeAction / startPluginAction
      |
      +-- expression --> InputDecision --> key_routing.routeKeyInput / pasteExpression
      |
      +-- failure --> lua_action.publishLuaFailure -> client_diagnostic.replace
                               |
                  client_diagnostic.replace
                               |
                  ClientModel.diagnostic_revision
                               |
                    Client.presentation.observe after the turn
```

The host consumes the router decision through `actions.executeAction`.
`lua_action.executeLuaAction` translates an expression decision into
semantic keys or paste. The host adapter does not access the Lua generation,
plugin registry or diagnostic buffer. Built-in effects reuse `actions.executeAction`. Plugin effects reuse
the separate asynchronous [`plugin_action`](plugin-action.md) slice.

## State and ownership

The client owns one live `config.Generation`. It contains the bounded Lua VM
and closures for the active configuration generation. `config_adoption.completeConfigReload` builds
a complete replacement before swapping that pointer, registry and input router
together. The VM never enters `ClientModel` or the window's renderer.

`plugin_action.callbackContext` constructs the value passed to Lua from committed
client state. It contains sidebar visibility, tab count, active tab position,
pane count and focused pane identity. Lua receives a read-only table built from
that value. It cannot retain a Zig pointer or observe a half-applied model
transition.

The diagnostic banner is semantic client state. `ClientModel` owns its bounded
text and `diagnostic_revision`; configuration reloads, Lua actions and plugin
actions all enter through
[`client_diagnostic.replace`](client-diagnostic.md). Replacing equal text is a
no-op. Invalid UTF-8 or text beyond the fixed buffer is rejected before commit.

## Callback policy

`lua_action.evaluateLuaAction` owns this order:

1. capture one callback context from `ClientModel`;
2. invoke the exact callback generation and identity;
3. validate the complete returned batch;
4. clear an older diagnostic after validation succeeds;
5. apply effects sequentially until completion or client exit.

The config VM validates result shape, item count and action types while parsing
the callback result. `lua_actions.validateBatch` then resolves every plugin reference against
the current registry before any native effect runs. A missing registry or bad
plugin identity rejects the whole batch. This prevents an earlier sidebar,
tab or pane effect from committing before a later plugin error is discovered.

Effect application is ordered but not transactional. If a later
`model.to_runtime` write fails, earlier committed effects remain committed. A plugin effect starts the
normal plugin lifecycle and captures the model context current at that point in
the sequence.

## Expression policy

An expression returns `consume`, `forward_binding`, semantic keys or bounded
paste. After a successful invocation, the operation clears any older
diagnostic and returns the value to `lua_action.executeLuaAction`. Keys pass through
`key_routing.routeKeyInput`; paste passes through
`pane_input.pasteExpression`. Both use the focused child's acknowledged
terminal modes and the existing pane-input target checks.

An expression does not return a terminal-encoding result. The client encodes
semantic keys after Lua returns, while paste follows the child's bracketed
paste mode. A name prompt suppresses the configured action before Lua runs.
Copy mode receives returned keys through normal key routing and suppresses a
returned paste before pane delivery.

## Failure and bounds

A missing live generation leaves state unchanged. A stale reference, Lua
error, instruction exhaustion, deadline or malformed result consumes the
matched binding and commits the bounded diagnostic produced by the VM. A
validation failure follows the same model path. Neither branch requests a
draw; the adapter observes `Version.diagnostic` after the turn.
Invalid diagnostic bytes are replaced by the operation with an explicit
error-name-only fallback.

The synchronous callback path keeps its existing hard limits:

- 16 MiB for the client configuration VM;
- 100,000 callback instructions, about 2 ms of work;
- a 100 ms callback deadline, the safety net checked between instructions;
- 16 effects per callback; a callback that returns more runs the first 16
  and reports `config.max_callback_effects`;
- 16 semantic keys per expression;
- 4 KiB of expression paste.

Bar, panel and pick renders are not key presses: they run on the loop
between events, under 1,000,000 instructions and the same 100 ms deadline.
A pick `items` function that turns a full list of 4096 options into tables
takes about 61,000 instructions.

Only an explicit Lua binding enters this path. Native bindings do not enter
Lua. The VM has no ambient filesystem, process, network, debug or native-module
authority.

## Validation

- `src/model/state/tests/configuration_and_host.zig` proves callback-context
  projection, diagnostic validation, equality and revision behavior.
- `src/client/config/client_diagnostic.zig` proves shared
  diagnostic validation, fallback and clear semantics.
- `src/client/input/lua_action.zig` owns invocation, validate-before-apply order,
  diagnostic order, sequential exit and failure classification
  (`evaluateLuaAction`), and router control, semantic-key reinjection and
  copy-mode paste suppression (`executeLuaAction`).
- `src/client/config/` proves immutable context, callback quotas,
  bounded result parsing and semantic input construction.
- `src/client_tests/configuration.zig` proves real VM evaluation, complete
  plugin prevalidation, semantic key and bracketed-paste delivery, copy-mode
  suppression and presentation observation of callback failures.
