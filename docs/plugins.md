# Lua plugins

A Telar plugin is a local package containing `plugin.json`, a Lua entrypoint,
and optional local Lua modules. Plugin code never runs in the runtime or client
process. Each invocation starts an isolated one-shot Telar worker with an empty
environment, safe Lua libraries, and hard memory, instruction, wall-time,
stdout, stderr, and concurrency bounds.

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
