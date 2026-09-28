# Link opening

Telar shares bounded URI recognition and opening between the shared client and
the native adapter. In the GUI, hovering a link needs no modifier: the pointer
becomes a hand, the visible spans get an accent underline and a card beside the
row names the destination. A plain left press stays with the pane, so a drag
still selects text; releasing without motion on the same presented link opens
it. The platform modifier ([Ghostty’s
convention](https://ghostty.org/docs/config/reference#link-url): Command on
macOS, Control on Linux) claims the whole gesture instead, so nothing reaches
the pane. When the child owns mouse reporting the plain button is the child’s;
hold Shift, with or without the modifier, to open. A right press copies the URI
to the clipboard and shows the copy toast. Alt keeps the text plain for
selection. Leaving the window, losing focus, changing geometry or switching
context cancels a pending open.

The GUI recognizes visible URLs across VT-confirmed soft wraps, inline Markdown
links (`[label](destination)`, the form coding agents print) whose whole
bracketed span acts as one link, OSC 8 links whose label differs from their
URI, and local file paths printed as plain text. Explicit links take precedence
over textual recognition, and a URI over a path. The card
(`LinkTooltip`) sits above the hovered row, or below it when the pane has no
room above, stays inside the pane content and wraps the URI to at most twelve
rows. Its delivered cells consume pointer gestures until another frame removes
it; covered terminal text cannot receive a click. A pane too short for a card
keeps the underline alone. Distinct OSC 8 identities with the same URI remain
distinct groups. A hard newline never joins text into a URL.

Supported explicit schemes are `http`, `https`, `file`, `mailto`, `ftp`, `ssh`,
`git`, `tel`, `magnet`, `ipfs`, `ipns`, `gemini`, `gopher` and `news`.
User-defined link matchers are outside this implementation. An unsupported,
invalid, overlong or omitted explicit destination cannot authorize its label as
a substitute URL. A Markdown label is at most 512 bytes; a longer, unterminated
or angle-bracketed form stays plain text, and its bare URI is still recognized.

## File paths in prose

Compilers and coding agents print paths as plain text: `src/main.zig:12`,
`./a/b.c:7:2`, `~/.claude/settings.json`, `/tmp/report.md`. `urlscan.pathAt`
recognizes them lexically, without touching the filesystem, as the last resort
after OSC 8, Markdown and URIs:

- an absolute path, a home path (`~/`) or a dot-relative path (`./`, `../`);
- a project path with a slash whose file name has an extension
  (`docs/flows/link-opening.md`); bare words with slashes such as `and/or` are
  prose;
- a bare file name only with a line (`main.zig:40`).

A path never contains `:`, so each colon-separated segment of a token is a
candidate and the digits after it are its `:line[:column]`. A range such as
`:5-9` points at its first line. Sentence periods and the non-ASCII decoration a
TUI draws around a path (box drawing, bullets, ellipses) are not part of it.

A path is a guess, so the GUI treats it as a link only while the platform
modifier is held: without Cmd (Ctrl on Linux) it is plain text for selection and
shows no underline. Nothing checks the file on hover; the runtime does when the
link is opened.

`file://` links carry a line too: a fragment of `12`, `L12`, `L12:3`, `L12C3` or
a range such as `L12-L20` (kitty's and GitHub's forms) becomes the line and
column. Any other fragment and any query still reject the link.

```text
VT RenderState -> TextMetadataCapture -> pane_frame -> owned client Pane
                                                           |
native event -> GuiAdapter.acceptInput -> InputQueue
GuiAdapter.drainInput -> dispatchPointer -> hover_target.resolve
                                      |                    |
                                LinkGesture           LinkRegions
                                      |              underline + card
                          HostChrome.link_pointer_fn
                                      |
             link_opening.openLink -> editor_file_links or links/host.zig worker
```

## Ownership and budgets

The runtime owns VT hyperlinks and physical-row wrap semantics. Core owns their
bounded wire representation and the pure URI classifier. Each client pane owns
its received metadata, independent of the socket buffer. See
[pane frames](pane-frame.md#terminal-text-metadata) for application and ACK rules.

`model.cells.resolve` (`src/model/links/cells.zig`) gives OSC 8 priority and otherwise traverses the
visible logical line. It copies a bounded text window to stack storage, with
independent byte and cell-visit limits, then returns an owned URI and cell range:
a Markdown link’s whole span with its destination (`urlscan.markdownLinkAt`),
else the bare URI under the position (`urlscan.extractAt`). No row cache, regex
engine, URL opener or allocation runs for movement within the same cell and
unchanged model/control state. URI length is limited to 4,096 bytes; overlong
targets are rejected rather than truncated.

The native adapter owns hover, prepared/shown target identities, and the pressed
link. A URI newly received from the runtime is not openable until that same target
was presented. GPU completion publishes only the identity captured by that flight;
it does not ACK cells. URI or context changes during a press cancel it permanently,
even if the original state subsequently returns. A captured link consumes its
whole gesture, including stationary modifier motion, without leaking child input.
A plain press arms the same gesture beside the pane’s own selection; any drag
cancels it and the selection goes on.

Underline and card use the existing retained glyph atlas and frame quads.
They do not invalidate terminal cell meshes. Native pointer shape changes alone
require no GPU frame, timer or polling. Browser launch uses the existing bounded
worker and never blocks input or presentation.

## Shared opening policy

The optional `HostChrome.link_pointer_fn` is an adapter hit test. GUI implements
its press policy there (`src/gui/ports/chrome.zig`). An adapter without the
callback, such as the client integration tests' `ClientHarness`, keeps the
shared default in `link_opening.inputLinkPointer`: an ordinary left press opens
a row-local textual or Markdown link, and Shift declines opening for selection.
Copy mode uses `o`. The common client contains no GUI gesture policy.

`link_opening.openLink` sends supported non-file schemes through
`model.link_opening` (`Opening`): at most one worker and one replaceable pending
target per client. It queues the worker with `client.to_background.push(.{ .link
= target })`; `src/client/links/host.zig` uses `/usr/bin/open` on macOS,
`xdg-open` on Linux, or `rundll32.exe url.dll,FileProtocolHandler` on Windows.
It passes the URI as one argument, captures bounded output, and expires after
five seconds. Failure emits an in-app warning.

`file://` links and paths open through
[editor file links](editor-file-links.md) from the pane they were printed in:
the runtime checks that the file exists, reuses an editor running in that tab or
the client splits one beside the source pane, and the editor starts at the
line. A relative path resolves against the source pane's directory and `~`
against HOME, lexically, before the request leaves the client. Without a source
pane (a CLI `open-link` with no focused pane) an absolute file opens in a new
tab. Empty authority and `localhost` are local. Remote hosts, user information,
ports, queries, non-position fragments, malformed escapes and decoded NUL are
rejected. No command or URI is evaluated through a shell.

## Validation

- `lib/urlscan`: scheme allowlist, punctuation, Unicode, Markdown link bounds, length limits,
  path recognition and `:line:column` and `#L` positions.
- `src/model/links/cells.zig`: row, OSC 8 and soft-wrap resolution.
- `src/backend/pane/TextMetadataCapture.zig`: VT identity, wide cells, wrap and quotas.
- `src/gui/tests/links.zig`, `link_regressions.zig`, `link_metadata.zig`: release
  ownership, presented identity, cancellation, metadata and retained rendering.
- `tools/gui_links.py`: isolated AppKit gestures, native cursor assertions,
  destination preview, recording editor and child survival.
- `tools/gui_path_links.py`: Cmd+click on relative, home and missing paths and on a
  `file://…#L4` link, against an editor stub named `nvim` that records its argv.
- `tools/vm/gui-links-test.py`: Wayland gestures through QEMU, a recording
  `xdg-open`, OSC 8/soft-wrap targets, Vulkan validation and child survival.

Native probes own window focus and must run sequentially on each desktop. They
use separate sockets, history and configuration; no real URL is launched.
