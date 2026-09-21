# Host flow simplification

Branch: `refactor/client-world-storage`. Base: `eaeac51f`.

Host startup, resize and terminal capability negotiation previously constructed
handlers and callback tables that forwarded the same model and client through
multiple files. Resource delivery then used a second callback table to invoke
the host ports already present on `AttachedClient`.

`src/client/operations/host/host_resources.zig` now owns the complete shared
operation. `apply` and `observe` commit through the model, then `deliver` checks
the commit and calls the host ports in order. `reconcile` resolves the cell size
when capability probes settle. GUI and TUI call these functions directly.

## Removed layers

- `ResizeHostHandler` and `HostResizeEffects`.
- `HostCapabilitiesHandler` and `HostCapabilitiesEffects`.
- `DeliverHostResourcesHandler`, `HostResourceDeliveryEffects` and its
  intermediate `SidebarConfiguration` value.
- Adapter callbacks that existed only to forward the client and commit.

Seven production files and six obsolete test/capture files were removed.
Contract tests now exercise the actual shared policy through the existing
host ports; they do not require a second production effects interface.

```text
Before:
GuiClient.start
  → ResizeHostHandler.execute
  → GuiClient.deliverResize
  → host_resources.deliver
  → DeliverHostResourcesHandler.execute
  → host_resources.invalidateGraphicsPlacements
  → HostGraphics.invalidatePlacements
  → host_ports.invalidatePlacements

After:
GuiClient.start
  → host_resources.apply
  → host_resources.deliver
  → HostGraphics.invalidatePlacements
  → host_ports.invalidatePlacements
```

This path goes from seven source-level calls to four. Its remaining port
separates the GUI and TUI implementations. The host-update subtree in the first
GUI startup goes from depth nine to six. These counts are not optimized stack
measurements or performance claims.

The fresh GUI explicitly calls `runtime_io.pump` after queuing bootstrap and
admitting a read. Previously the initial send was a side effect of
`flushGraphicsCredits`, even though a fresh GUI has no graphics credits. Live
credit delivery still flushes and pumps the queue as before.

## Preserved contracts

- Geometry and capabilities are validated before mutation.
- Empty/stale commits are rejected before resource effects.
- Exact repeated observations cause no resource calls.
- Colors precede appearance; graphics fallbacks precede sidebar configuration
  and placement invalidation.
- Grid changes resize presentation before chrome. Cell-size changes configure
  the sidebar. Placement invalidation precedes pane geometry and attachments.
- Delivery stops at the first failure and retains the committed model.
- Runtime transport buffers, producer reservations, graphics credits and
  asynchronous lifetimes are unchanged.
- The shared client imports neither GUI nor TUI.

## Validation

Verified locally on 2026-09-21 with Zig 0.16.0 on macOS:

| Check | Result |
| --- | --- |
| Shared client | 969 tests passed |
| TUI | 599 tests passed |
| GUI | 745 tests passed |
| Client boundaries | Passed, including 19 checker tests |
| Zig codestyle | Passed |
| Executable build | Passed, 51/51 build steps |
| Diff whitespace | Passed |

`src/frontend/client/tests/host_resources.zig` replaces thirteen handler-level
tests with six contract tests. Cases cover stale capability and geometry
commits, empty commits, no-op/invalid updates, grid-only/cell-only/combined
updates, failure at each fallible host resource port, ordered graphics delivery
and retained state after failure. Existing `host_interaction.zig` tests still
cover actual resources, pane fallbacks and outbox backpressure.

`src/gui/tests/terminal.zig` adds a startup regression that consumes all three
bootstrap messages in order without a server reply or any graphics credits.
It checks that the client remains in `opening` until runtime state arrives.

Validation commands use Homebrew Python on PATH because the local mise shim
tries to install an unavailable Python artifact:

```sh
PATH=/opt/homebrew/bin:$PATH zig build test-client
PATH=/opt/homebrew/bin:$PATH zig build test-frontend
PATH=/opt/homebrew/bin:$PATH zig build test-gui
PATH=/opt/homebrew/bin:$PATH zig build check-client-boundaries codestyle
PATH=/opt/homebrew/bin:$PATH zig build
```

No window or runtime session is launched by this change. The user's existing
formatting edits in `GuiClient.init` are retained.
