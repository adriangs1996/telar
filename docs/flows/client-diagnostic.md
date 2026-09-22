# Client diagnostic state

The client diagnostic is one disposable, bounded banner shared by Lua actions,
configuration reloads and plugin execution. Producers decide the message and
whether it also needs a notification.

```text
AttachedClient.evaluateLuaAction / AttachedClient.completeConfigReload / completePluginAction
  → client_diagnostic.replace(model, replacement)
      validate primary text; optionally validate the explicit fallback
      model.replaceDiagnostic
  → producer may publish a notification from the committed banner
  → event-loop presentation observes the diagnostic revision
```

The helper is a function over the model. Producers clear successful prior
failures with `model.clearDiagnostic`. There is no diagnostic object to assemble
or erased callback to invoke.

`Diagnostic` retains at most 512 bytes and validates length and UTF-8 before
mutation. If both the primary value and explicit fallback are invalid, the old
banner survives. Equal text is a no-op. A real replacement or removal advances
the diagnostic revision once. `formatted` uses a bounded buffer and a static
fallback when formatting does not fit.

Configuration and plugin operations commit the banner before publishing a
notification. Notification failure preserves it. Lua failures publish the banner
without a second notification. The model owns no drawing or timer scheduling.

Validation lives in the model's configuration tests,
`src/client/application/configuration/client_diagnostic.zig`, and the real
configuration/Lua/plugin flows in `src/frontend/client/tests/configuration.zig`.
