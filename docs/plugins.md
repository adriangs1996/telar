# Lua plugins

A Telar plugin is a local package containing `plugin.json`, a Lua entrypoint,
and optional local Lua modules. Plugin code never runs in the runtime or client
process. Each invocation starts an isolated one-shot Telar worker with an empty
environment, safe Lua libraries, and hard memory, instruction, wall-time,
stdout, stderr, and concurrency bounds.

Plugins may also register a runtime-side exchange listener. Unlike action
workers, each listener remains alive for the runtime lifetime so it can inspect
completed ProxyTLS exchanges while every client is disconnected.

## Try the example plugin

Start from a source checkout with `telar` [on your PATH](usage.md#put-telar-on-your-path).
The included sample toggles the sidebar and requests no capabilities:

```sh
telar plugin inspect ./examples/plugins/sample
telar plugin install ./examples/plugins/sample
```

Inspection lists the package ID, version, actions and requested capabilities.
Installation prints an installed path under your data directory. Copy that
exact absolute path into the configuration below in place of
`/absolute/installed/plugin/path`. This is a complete trial config; when using
an existing file, merge the `plugins` and `client.keybindings` entries:

```lua
local telar = require("telar")

return telar.config({
  api_version = 2,
  plugins = {
    telar.plugin({ path = "/absolute/installed/plugin/path" }),
  },
  client = {
    keybindings = {
      telar.bind({ "o" }, telar.action.plugin({
        plugin = "dev.telar.sample",
        action = "toggle",
      })),
    },
  },
})
```

Run `telar config check` and save/reload the config. With the default prefix,
`Ctrl+b`, then `o` should toggle the sidebar. Installation alone does not enable
a plugin. The sample needs no trust grant; another plugin may need one of the
capabilities described below. Inspect what it requests before granting it.

To disable the sample, remove both its `plugins` entry and its binding, then
validate and reload. Leaving a binding that names an absent plugin fails
validation. Updating a package installs a new digest/path; update the config
and review any new capability grants rather than assuming trust transfers.

If it does not run, check the installed path, matching plugin/action IDs and
config validation output. Keep the previous config until the new one passes.
The rest of this page is the reference for package authors and capability grants.

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
finished. It may return at most 16 typed effects, all notifications, which
additionally require the `notifications` capability. Each worker has bounded
memory, execution time, frame size, stderr, queue depth, and restart rate.
When a queue is full, the oldest observation is dropped. Proxy relay never
waits for a listener.

Tap packages are loaded when the runtime starts. Client configuration reload
does not replace runtime tap workers because runtime reload does not yet exist.
Restart the runtime after changing the enabled package set or trust grants.

See [Proxy tap](flows/proxy-tap.md) for ownership and scheduling details.
