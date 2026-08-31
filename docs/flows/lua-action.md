# Lua action

This flow starts after the native input router matches a configured Lua
callback or expression. The callback VM may return semantic client effects or
semantic input. It never returns terminal bytes or mutates client objects.

## End-to-end path

```text
configured binding
      |
keybind.Router -> InputHandler.action
      |
action_routing -> ActionRoutingHandler
      |
lua_actions.execute
      |
LuaActionHandler
      |
ClientModel.callbackContext
      |
client-owned Generation.invokeCallback / invokeExpression
      |
      +-- callback --> EffectBatch --> validate complete batch
      |                                  |
      |                         client_actions / plugin_actions
      |
      +-- expression --> InputDecision --> key_routing / pane_inputs
      |
      +-- failure --> ClientModel.replaceDiagnostic
                               |
                  ClientModel.Version.diagnostic
                               |
                    presentation_lifecycle.observe -> Presenter
```

`InputHandler` only delegates the routed value. `ActionRoutingHandler`
classifies its source and translates an expression decision into semantic keys
or paste. It does not access the Lua generation, plugin registry or diagnostic
buffer. Built-in effects reuse `client_actions.apply`. Plugin effects reuse
the separate asynchronous [`pluginAction`](plugin-action.md) slice.

## State and ownership

The client owns one live `config.Generation`. It contains the bounded Lua VM
and closures for the active configuration generation. `config_reloads` builds
a complete replacement before swapping that pointer, registry and input router
together. The VM never enters `ClientModel` or the presenter.

`ClientModel.callbackContext` constructs the value passed to Lua from committed
client state. It contains sidebar visibility, tab count, active tab position,
pane count and focused pane identity. Lua receives a read-only table built from
that value. It cannot retain a Zig pointer or observe a half-applied model
transition.

The diagnostic banner is semantic client state. `ClientModel` owns its bounded
text and `Version.diagnostic`; configuration reloads, Lua actions and plugin
actions all use the same owner. Replacing equal text is a no-op. Invalid UTF-8
or text beyond the fixed buffer is rejected before commit.

## Callback policy

`LuaActionHandler` owns this order:

1. capture one callback context from `ClientModel`;
2. invoke the exact callback generation and identity;
3. validate the complete returned batch;
4. clear an older diagnostic after validation succeeds;
5. apply effects sequentially until completion or client exit.

The config VM validates result shape, item count and action types while parsing
the callback result. `lua_actions` then resolves every plugin reference against
the current registry before any native effect runs. A missing registry or bad
plugin identity rejects the whole batch. This prevents an earlier sidebar,
tab or pane effect from committing before a later plugin error is discovered.

Effect application is ordered but not transactional. If a later outbox write
fails, earlier committed effects remain committed. A plugin effect starts the
normal plugin lifecycle and captures the model context current at that point in
the sequence.

## Expression policy

An expression returns `consume`, `forward_binding`, semantic keys or bounded
paste. After a successful invocation, the application handler clears any older
diagnostic and returns the value to `ActionRoutingHandler`. Keys pass through
`key_routing` and `KeyRoutingHandler`; paste passes through
`pane_inputs.expressionPaste`. Both use the focused child's acknowledged
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
validation failure follows the same model path. Neither branch calls
`Presenter.requestDraw`; `client_events` publishes `Version.diagnostic`.
Invalid diagnostic bytes are replaced with an error-name-only fallback.

The synchronous callback path keeps its existing hard limits:

- 16 MiB for the client configuration VM;
- 100,000 callback instructions;
- 10 ms callback deadline;
- 16 effects per callback;
- 16 semantic keys per expression;
- 4 KiB of expression paste.

Only an explicit Lua binding enters this path. Native bindings do not enter
Lua. The VM has no ambient filesystem, process, network, debug or native-module
authority.

## Proof

- `src/frontend/client/model.zig` proves callback-context projection,
  diagnostic validation, equality and revision behavior.
- `src/frontend/client/application/lua_action.zig` proves invocation,
  validate-before-apply order, diagnostic order, sequential exit and failure
  classification.
- `src/frontend/client/application/action_routing.zig` proves source
  classification, router control, semantic-key reinjection and copy-mode paste
  suppression without VM knowledge.
- `src/frontend/config/root.zig` proves immutable context, callback quotas,
  bounded result parsing and semantic input construction.
- `src/frontend/client/client_test.zig` proves real VM evaluation, complete
  plugin prevalidation, semantic key and bracketed-paste delivery, copy-mode
  suppression and presenter observation of callback failures.
