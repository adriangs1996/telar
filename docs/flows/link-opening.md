# Link opening

Telar recognizes textual `http://`, `https://` and `file://` URIs in pane
cells. A left click over one, or `o` with the copy-mode cursor over one,
produces the same owned `links.Target` value.

```text
pane cells + position
        |
links.extract -> core.link.extractAt/classify
        |
OpenLinkHandler
        |
        +-------------------------+
        |                         |
     file://                 http:// or https://
        |                         |
FilePath decode             Opening latest-wins state
        |                         |
create_tab($EDITOR, path)   client worker
                                  |
                     default host URL handler
```

## Ownership and budget

The client owns the copy cursor, pointer gesture, extracted target, `$EDITOR`
snapshot and host worker. Core owns no state. `core.link` only classifies and
extracts bytes. `frontend.links.cells` is the adapter between pane cells and
that pure API.

Cell extraction runs on the interactive path without allocation. It inspects
one bounded row window and copies at most 8,224 bytes to the stack. Each URI is
limited to 4,096 bytes. Opening a `file://` target only enqueues the existing
tab-creation request. Starting a host URL handler runs on an observation worker
and never blocks pane input or rendering.

Only local file authorities are accepted. An empty authority and `localhost`
map to the decoded absolute path. User information, ports, remote authorities,
queries, fragments, malformed escapes and decoded null bytes are rejected.
The client passes `$EDITOR` as `argv[0]` and the decoded path as `argv[1]`; it
does not evaluate the variable through a shell.

One host opener worker may run per client. While it runs, a new web target
replaces the previous pending target. Completion starts that latest target or
returns the state to idle. Worker startup failure and nonzero or timed-out host
commands publish a bounded in-app warning.

## Pointer and copy-mode authority

`PointerRoutingHandler` keeps its existing copy-mode and client-view priority.
After the view accepts pane input, textual links get refusal before child mouse
reporting. A left press over a link opens it and owns that gesture. Matching
drag and release events never leak to the child. A press outside a link leaves
pane mouse behavior unchanged.

Active copy mode already owns every pointer event, so it opens links through
the `o` key instead. `ClientModel.planCopyMode` resolves the target from the
same cell adapter. `CopyModeHandler` dispatches it without committing copy
state, changing the viewport or leaving the mode.

## Platform adapters

The host worker uses `/usr/bin/open` on macOS, `xdg-open` on Linux and
`rundll32.exe url.dll,FileProtocolHandler` on Windows. It passes the URI as one
argv entry, captures bounded output and expires after five seconds.

## Proof

- `src/core/link.zig` proves classification, cursor-relative extraction and
  punctuation boundaries.
- `src/frontend/links/cells.zig` proves absolute pane-coordinate adaptation.
- `src/frontend/links/file_uri.zig` proves local file decoding and rejection.
- `src/frontend/links/opening.zig` proves one active worker and latest-wins
  queuing.
- `src/frontend/links/pointer.zig` proves whole-gesture ownership.
- `src/frontend/client/application/input/open_link.zig` proves scheme dispatch.
- `src/frontend/client/application/input/copy_mode.zig` proves that `o`
  dispatches without a copy-state commit.
- `src/frontend/client/tests/host_interaction.zig` proves both file-opening
  triggers reach `create_tab` as `[$EDITOR, decoded_path]`.
