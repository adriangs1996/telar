# Lua plugins

A Telar plugin is a local package containing `plugin.json`, a Lua entrypoint,
and optional local Lua modules. Plugin code never runs in the runtime or client
process. Each invocation starts an isolated one-shot Telar worker with an empty
environment, safe Lua libraries, and hard memory, instruction, wall-time,
stdout, stderr, and concurrency bounds.

Plugins may also register a runtime-side exchange listener. Unlike action
workers, each listener remains alive for the runtime lifetime so it can inspect
completed ProxyTLS exchanges while every client is disconnected.

## Package identity

`plugin.json` is declarative and is parsed before Lua executes:

```json
{
  "api_version": 1,
  "id": "dev.example.plugin",
  "version": "1.0.0",
  "entry": "plugin.lua",
  "source": {
    "url": "https://example.invalid/plugin.git",
    "revision": "0123456789abcdef"
  },
  "actions": ["toggle"],
  "capabilities": ["runtime.control"]
}
```

Telar rejects unknown manifest fields, invalid identifiers, duplicate actions
or capabilities, absolute and escaping entry paths, symlinks, unsupported file
types, packages above 256 filesystem entries, and packages above 16 MiB. Its SHA-256 identity
covers every relative path and every file byte in deterministic order, not only
the manifest and entrypoint.

Inspection, installation, trust, enablement, and execution are separate:

```sh
telar plugin inspect ./my-plugin
telar plugin install ./my-plugin
telar plugin trust ./my-plugin --capability runtime.control
```

Installation copies the validated tree atomically to
`$XDG_DATA_HOME/telar/plugins/<id>/<sha256>/`, with owner-only permissions. It
does not edit `config.lua` and does not trust the package. Enable a package by
adding its installed path to `config.plugins`.

Trust grants live in `$XDG_CONFIG_HOME/telar/trust.json`, use owner-only
permissions, and bind the plugin ID, exact package digest, and selected declared
capabilities. Changing any package byte invalidates its old grant. Trusting a
package never enables it.

## Actions and authority

An entrypoint returns an action table:

```lua
local telar = require("telar")

return {
  actions = {
    toggle = function(ctx)
      return telar.action.toggle_sidebar()
    end,
  },
}
```

Configuration binds it through stable plugin and action IDs:

```lua
telar.bind(
  { "p" },
  telar.action.plugin({ plugin = "dev.example.plugin", action = "toggle" })
)
```

The worker receives only the immutable callback snapshot. It has no inherited
credentials, filesystem API, process API, network API, native module loader, or
runtime socket. It returns a bounded binary batch of semantic effects. The
client validates the entire batch, rejects Lua/plugin recursion, verifies that
the worker still belongs to the configured package digest, and checks each
privileged effect against the capability broker before applying any effect.
Before spawning Lua, the broker copies the configured package into a private
owner-only directory and rehashes the copy. The worker executes that invocation
snapshot, closing the inspection-to-execution mutation window.

Each invocation also carries a client-owned execution identity and the active
configuration generation. Only its exact completion can clear the run. A
completion from a replaced configuration is consumed without authorizing or
applying its effects. See [Plugin action](flows/plugin-action.md) for the full
client lifecycle.

`runtime.control` is currently required for effects that create, rename, move,
or close runtime-owned panes or tabs, or detach the client. Other declared
capabilities are reserved until a typed broker API exists; declaring or
granting one does not expose ambient operating-system authority. The exception
is `notifications`, which permits the bounded
`telar.action.notification({...})` semantic effect. It grants no socket,
filesystem, process, or network access; the client broker publishes the effect
on the plugin's behalf after verifying the package digest and grant.

A future API that exposes workspace files, process spawning, native code, or
network access must state that a same-user plugin with such authority is
full-trust code. A Lua VM is a containment boundary for failure and resource
usage, not an operating-system sandbox.

## Exchange listeners

An enabled package that declares and is granted `proxy.tap` may return an
`on_exchange` callback from its entrypoint:

```lua
local telar = require("telar")

return {
  on_exchange = function(exchange)
    if exchange.status >= 500 then
      return {
        telar.effect.notification({
          level = "warning",
          title = "Upstream failure",
          message = exchange.host,
        }),
      }
    end
  end,
}
```

`proxy.tap` is full-trust authority. The callback receives unredacted request
and response headers and captured body bytes, including credentials such as
`authorization` and cookies. A per-body flag states whether content coding was
decoded successfully. Grant it only to code you have audited. Telar binds the
grant to the exact package digest, copies the package into a private owner-only
snapshot, and rehashes it before starting the worker.

The callback receives one immutable table only after the whole exchange has
finished. It may return at most 16 typed effects. `agent_evidence` requires
`proxy.tap`; notifications additionally require `notifications`; command
persistence additionally requires `history.write`. Each worker has bounded
memory, execution time, frame size, stderr, queue depth, and restart rate.
When a queue is full, the oldest observation is dropped. Proxy relay never
waits for a listener.

Tap packages are loaded when the runtime starts. Client configuration reload
does not replace runtime tap workers because runtime reload does not yet exist.
Restart the runtime after changing the enabled package set or trust grants.

### Shipped agent-command classifier

[`examples/plugins/agent-commands`](../examples/plugins/agent-commands) is the
reference implementation of the user-classifies model. It recognizes
Anthropic `tool_use` blocks and OpenAI Responses `function_call` items, joins
streamed `input_json_delta` and `response.function_call_arguments.delta`
fragments, and decodes the completed arguments with `telar.json.decode`. The
exact command mappings are `Bash.command`, `shell.command`, and
`exec_command.cmd`; other tools, malformed JSON, and truncated response bodies
are ignored. Bodies whose content coding could not be decoded are also ignored.

Inspect, install, and grant the three declared capabilities explicitly:

```sh
telar plugin inspect ./examples/plugins/agent-commands
telar plugin install ./examples/plugins/agent-commands
telar plugin trust ./examples/plugins/agent-commands \
  --capability proxy.tap \
  --capability history.write \
  --capability notifications
```

The install command prints the immutable package path. Add that path to
`config.plugins`, enable `runtime.proxy.capture`, and restart the runtime:

```lua
plugins = {
  telar.plugin({
    path = "/absolute/path/printed/by/telar/plugin/install",
    enabled = true,
  }),
}
```

The plugin labels Anthropic traffic as provider `claude` and OpenAI Responses
traffic as provider `codex`. A record describes the command requested by the
model response; native harness hooks remain the authoritative execution source
and update the same `tool_call_id` when available. Persistence applies Telar's
secret filters because the plugin sets `redact = true`. The informational
notification is emitted only when at least one command effect was produced.

See [Proxy tap](flows/proxy-tap.md) for ownership and scheduling details.
