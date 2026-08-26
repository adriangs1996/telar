# Notifications

Telar exposes one notification path for the CLI, Lua configuration, and Lua
plugins. A request enters the runtime over the local protocol, the runtime
validates its bounds and broadcasts it, and each connected UI client copies it
into disposable toast state. Notifications are not persisted and never become
runtime lifecycle state.

## CLI

```sh
telar notification show "Build complete" \
  --body "Open the pane" \
  --level success \
  --duration 5000 \
  --pane 42
```

The title is required. `--body` is optional; `--level` accepts `info`,
`success`, `warning`, or `failure`; `--duration` accepts 500 through 60000
milliseconds. `--pane ID`, `--tab ID`, and `--workspace ID` are mutually
exclusive click targets. `--socket PATH` selects an explicit runtime; otherwise
the normal `TELAR_SOCKET` and managed-runtime resolution applies.

The command exits successfully only when at least one UI client accepted the
notification. It reports an error when no UI is connected instead of claiming
that an invisible notification was shown. It also does not start an idle
runtime merely to report that no UI exists.

## Lua and plugins

Configuration callbacks return a semantic notification effect:

```lua
return telar.action.notification({
  title = "Agent waiting",
  body = "Review its question",
  level = "warning",
  duration_ms = 4000,
  pane_id = ctx.focused_pane_id,
})
```

A plugin returns the same value from one of its actions and declares the
`notifications` capability in `plugin.json`:

```json
{
  "capabilities": ["notifications"]
}
```

The exact package digest must also be trusted for that capability:

```sh
telar plugin trust ./my-plugin --capability notifications
```

Plugin workers never receive the runtime socket. Their bounded binary result
is decoded and authorized by the client broker, which emits the runtime request
only after the whole effect batch passes validation.

## Bounds and interaction

Titles are limited to 48 UTF-8 bytes, bodies to 192 bytes, and each client
keeps at most four notifications. A fifth replaces the oldest. Toasts animate
in and out on a continuous smoothstep curve sampled at the client's frame
cadence. Their duration is time-based, so dropped frames do not stretch the
transition; once stable, the client sleeps until the next expiry instead of
polling. Toasts can be dismissed explicitly, and click targets are semantic
IDs; a pane, tab, or workspace that disappeared before the click is safely
ignored.

## Rendering

When the client has confirmed Kitty Graphics support and knows the host cell
size, it shapes UTF-8 with HarfBuzz and rasterizes the resulting glyphs into
RGBA with FreeType and the embedded JetBrains Mono face. Rasterization and image
transfer wait until the media path is idle. A texture is regenerated only when
its content, theme, or pixel geometry changes; the 200 ms transition updates
only a native-size KGP source crop and placement, so the smoothstep curve keeps
pixel precision instead of snapping to columns.

The renderer owns at most four 1.5 MiB images and transfers at most one during
an idle graphics pass. Until every visible image has reached the host, the
whole stack remains cell-rendered. Unsupported KGP, terminal-derived colors,
missing glyphs, oversized geometry, allocation failure, resize, and renderer
initialization failure all take the same path: remove graphical placements and
keep the clickable cell renderer. The hit targets remain cell-owned even while
KGP supplies the pixels.
