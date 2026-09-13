# Link opening

Telar shares bounded URI recognition and opening between its terminal and native
adapters. Native URL hover follows [Ghostty’s modifier convention](https://ghostty.org/docs/config/reference#link-url):
Command on macOS, Control on Linux. Hold Shift as well when the child owns mouse
reporting. A left press acquires the gesture; release opens the unchanged target.
Dragging, leaving the window, losing focus, changing geometry or switching context
cancels it. Modifier changes re-evaluate a stationary pointer.

The GUI recognizes visible URLs across VT-confirmed soft wraps, and OSC 8 links
whose label differs from their URI. Explicit links take precedence over textual
recognition. Hover underlines the matching spans and shows the actual destination
in a clipped pane-local preview. Its delivered rectangle consumes pointer gestures
until another frame removes it; covered terminal text cannot receive a click.
Single-row panes keep the underline without a preview that would cover the link. Distinct OSC 8 identities with the same URI remain
distinct groups. A hard newline never joins text into a URL.

Supported explicit schemes are `http`, `https`, `file`, `mailto`, `ftp`, `ssh`,
`git`, `tel`, `magnet`, `ipfs`, `ipns`, `gemini`, `gopher` and `news`. Relative paths
and user-defined link matchers are outside this implementation. An unsupported,
invalid, overlong or omitted explicit destination cannot authorize its label as
a substitute URL.

```text
VT RenderState -> TextMetadataCapture -> pane_frame -> owned client Pane
                                                           |
native event -> NativeInput -> PointerRouting -> hover_target / resolveLink
                                      |                    |
                                LinkGesture           LinkRegions
                                      |              underline + preview
                          HostChrome.link_pointer_fn
                                      |
                    OpenLinkHandler -> file tab or host worker
```

## Ownership and budgets

The runtime owns VT hyperlinks and physical-row wrap semantics. Core owns their
bounded wire representation and the pure URI classifier. Each client pane owns
its received metadata, independent of the socket buffer. See
[pane frames](pane-frame.md#terminal-text-metadata) for application and ACK rules.

`client.links.cells.resolve` gives OSC 8 priority and otherwise traverses the
visible logical line. It copies a bounded text window to stack storage, with
independent byte and cell-visit limits, then returns an owned URI and cell range.
No row cache, regex engine, URL opener or allocation runs for movement within the
same cell and unchanged model/control state. URI length is limited to 4,096 bytes;
overlong targets are rejected rather than truncated.

The native adapter owns hover, prepared/shown target identities, and the pressed
link. A URI newly received from the runtime is not openable until that same target
was presented. GPU completion publishes only the identity captured by that flight;
it does not ACK cells. URI or context changes during a press cancel it permanently,
even if the original state subsequently returns. A captured link consumes its
whole gesture, including stationary modifier motion, without leaking child input.

Underline and preview use the existing retained glyph atlas and frame quads.
They do not invalidate terminal cell meshes. Native pointer shape changes alone
require no GPU frame, timer or polling. Browser launch uses the existing bounded
worker and never blocks input or presentation.

## Shared opening policy and the TUI

The optional `HostChrome.link_pointer_fn` is an adapter port. GUI implements its
modifier/release policy there. An absent callback retains TUI behavior: ordinary
left press opens a row-local textual link, Shift declines opening for selection,
and copy mode uses `o`. The common client contains no GUI gesture policy.

`OpenLinkHandler` sends supported non-file schemes through `Opening`: at most one
worker and one replaceable pending target per client. The worker uses
`/usr/bin/open` on macOS, `xdg-open` on Linux, or
`rundll32.exe url.dll,FileProtocolHandler` on Windows. It passes the URI as one
argument, captures bounded output, and expires after five seconds. Failure emits
an in-app warning.

`file://` preserves Telar’s editor policy: decode a local absolute path and create
a tab with `[$EDITOR, path]`. Empty authority and `localhost` are local. Remote
hosts, user information, ports, query/fragment, malformed escapes and decoded NUL
are rejected. No command or URI is evaluated through a shell.

## Proof

- `src/core/link.zig`: scheme allowlist, punctuation, Unicode, and length limits.
- `src/client/links/cells.zig`: row, OSC 8 and soft-wrap resolution.
- `src/backend/pane/TextMetadataCapture.zig`: VT identity, wide cells, wrap and quotas.
- `src/gui/tests/links.zig`, `link_regressions.zig`, `link_metadata.zig`: release
  ownership, presented identity, cancellation, metadata and retained rendering.
- `tools/gui_links.py`: isolated AppKit gestures, native cursor assertions,
  destination preview, recording editor and child survival.
- `tools/vm/gui-links-test.py`: Wayland gestures through QEMU, a recording
  `xdg-open`, OSC 8/soft-wrap targets, Vulkan validation and child survival.

Native probes own window focus and must run sequentially on each desktop. They
use separate sockets, history and configuration; no real URL is launched.
