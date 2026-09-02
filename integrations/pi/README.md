# Telar + Pi

Telar knows Pi without configuration: a Pi process in a pane is identified by
its executable and entry point, and `pi --session <id>` restores it after a
runtime restart. Two optional pieces make the integration complete.

## Lifecycle reports

Pi has no hook files; its lifecycle reaches extensions as events. Install
Telar's extension once:

```sh
telar integration install pi
telar integration status pi
```

This writes `~/.pi/agent/extensions/telar.ts` from
[`src/cli/integration/pi.ts`](../../src/cli/integration/pi.ts) with the
Telar executable path filled in. Inside a Telar pane the extension runs
`telar hook pi` on `session_start`, `agent_start`, `agent_settled`,
`ui_prompt_start`, `ui_prompt_end` and `session_shutdown`; outside a pane it
does nothing. The runtime ranks these reports above proxy and screen
evidence, so the sidebar shows working, blocked and ready from Pi's own
events, and the session id lets Telar resume the session on restart.

`telar integration uninstall pi` removes the file only if it still starts
with the `// telar-integration: pi` marker.

## Pi as Telar's engine

`runtime.engine` in `config.lua` keeps one headless Pi alive in RPC mode for
features that need a model without a pane, starting with session titles:

```lua
runtime = {
  engine = {
    command = {
      "pi", "--mode", "rpc", "--no-session", "--no-tools",
      "--no-extensions", "--no-skills", "--no-context-files",
    },
    timeout_ms = 20000,
    idle_timeout_ms = 300000,
  },
}
```

See [`docs/flows/engine.md`](../../docs/flows/engine.md) for the runtime
path and bounds, and [`docs/flows/agent-hooks.md`](../../docs/flows/agent-hooks.md)
for the report mapping.
