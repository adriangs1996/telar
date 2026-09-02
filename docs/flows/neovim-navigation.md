# Neovim navigation

## Promise

`ctrl+h/j/k/l` crosses Neovim windows and Telar panes without changing the
ownership of either layout. Neovim owns its windows. The attached Telar client
owns Telar focus. The runtime routes requests but never stores or chooses focus.

## Native input path

The `navigate_pane` action handles a canonical directional key:

1. When the focused foreground process is `nvim`, the client forwards the key
   to the pane. Neovim and `smart-splits.nvim` get the first chance to move.
2. For any other process, the client asks its existing `FocusPaneHandler` for a
   neighbor in that direction.
3. If no Telar neighbor exists, the client forwards the original key. This
   preserves shell behavior such as `ctrl+l` and `ctrl+h` at an outer edge.

This path uses the cached foreground projection and the existing bounded input
outbox. It performs no filesystem access, process spawn, Lua evaluation, or
allocation.

## Neovim edge path

At a Neovim edge, the adapter runs:

```text
telar pane focus --current --direction <direction> --json
```

The command requires both `TELAR_PANE_ID` and `TELAR_PANE_GENERATION`. The
runtime rejects a stale generation. It then selects the active UI session that
most recently sent input to that exact pane generation. This is a routing hint,
not focus authority.

The runtime sends a bounded `pane_focus_command` to that UI. The UI verifies
that the source pane is still focused, applies the normal client-owned focus
use case, and returns `focused`, `no_neighbor`, or `source_not_focused`. The
runtime correlates the reply to the waiting control connection. A target UI
disconnect turns the pending request into a failure instead of leaving the CLI
waiting forever.

## Multi-client rule

The geometry lease never participates in focus routing. The last input origin
is causal: Neovim can only start the control command after the runtime has
accepted the triggering key from that UI. A completion must come from the same
generation-safe client session selected for the pending request.

## Proof

- The schema golden corpus pins all four navigation messages and bumps the
  handshake fingerprint.
- Client integration tests prove Neovim receives the canonical key, a shell at
  an outer Telar edge keeps the key, and external focus commands report a
  directionless layout.
- The headless Neovim test proves command construction, JSON decoding, and the
  one-shot pane identity used by `smart-splits.nvim`.

Installation, multiplexer coexistence, and live-session diagnostics are in the
[Neovim integration guide](../../integrations/nvim/README.md).
