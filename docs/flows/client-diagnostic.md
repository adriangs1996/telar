# Client diagnostic state

The client diagnostic is one disposable, bounded banner shared by Lua actions,
configuration reloads and plugin execution. Producers decide the message and
whether it also needs a notification.

```text
lua_action.evaluateLuaAction / config_adoption.completeConfigReload / completePluginAction
  → client_diagnostic.replace(model, replacement)
      validate primary text; optionally validate the explicit fallback
      model.replaceDiagnostic
  → producer may publish a notification from the committed banner
  → event-loop presentation observes the diagnostic revision
```

The helper is a function over the model. Producers clear successful prior
failures with `model.clearDiagnostic`. There is no diagnostic object to assemble
or erased callback to invoke.

`Diagnostic` retains at most 1024 bytes and validates length and UTF-8 before
mutation. If both the primary value and explicit fallback are invalid, the old
banner survives. Equal text is a no-op. A real replacement or removal advances
the diagnostic revision once. A message that does not fit keeps its start, cut
at a character, and ends with `…`, so a long Lua error keeps its detail.

Configuration and plugin operations commit the banner before publishing a
notification. Notification failure preserves it. Lua failures publish the banner
without a second notification. The model owns no drawing or timer scheduling.

The window draws the banner as a red chip at the right of the status bar,
cut to fit half the row, and the headless dump writes it as `diagnostic`.
Bars, panels and picks set it too. A bar slot whose render fails records the
diagnostic revision it left in `BarUpdatesState`, and that slot's next
successful render clears the banner unless something replaced it since; a
panel does the same. A failed panel keeps its reason in `Panel.reason` and
shows "Could not update: <reason>".

Validation lives in the model's configuration tests,
`src/client/config/client_diagnostic.zig`, and the real
configuration/Lua/plugin flows in `src/client_tests/configuration.zig`.
