# History browser

The approved compact design opens with `prefix+/`. Search stays below the
results, with the best/newest result nearest the prompt. Rows show duration,
relative time and exit status when the terminal has enough columns. The selected
row's cwd, author and pane appear above the search field. The native GUI keeps
the same order in its own panel above the status bar, with day headings, filter
chips and an inspector (see `src/gui/widgets/README.md`, "Command history").

## Ownership and delivery

The runtime owns SQLite history and captured output. The client owns the search,
loaded page, selection, inspection and scroll. Closing the client does not delete
history. No database work runs in the input handler.

`src/client/input/history_palette.zig` owns UI requests,
correlation, wire delivery and response application. It calls concrete bounded
algorithms in `src/client/input/history_browser.zig` against the
history and prompt model APIs. `widgets/history_browser.zig` renders cells with
the existing theme, grapheme handling and screen diff. It does not emit terminal
sequences or resize the child PTY.

The external flow is:

```text
history_palette action -> history_palette.beginHistoryPalette
  -> query_history -> runtime command_history.query -> observation worker -> SQLite
  -> history_results -> runtime_io.receiveRuntime -> runtime_messages.handleServerMessage
  -> history_palette.applyHistoryResults
  -> bounded model commit -> Version.history -> presenter -> history widget
```

No domain event crosses this flow: the client commits disposable query state and
publishes its existing presentation revision. Durable mutations remain in the
runtime's history worker.

## Query and pagination

Opening starts globally, filtered to human commands unless
`client.history.show_agent_commands = true`; that setting is only the initial
author filter. Tab cycles global, workspace, cwd and pane; Shift+Tab cycles the
author filter (you, agents, both); a leading `!` in the field, or the GUI's
failed chip, asks for failed commands only (`QueryHistory.failed_only`). The
filters live on the prompt (`Prompt.mode.history`), and
`history_palette.historyFilters` turns the field and the prompt into the wire
query. Unavailable context (no workspace path, no working directory yet)
falls back to global, and the displayed scope is the effective scope. A
workspace path or working directory travels in its outbox slot's payload,
up to `core.max_cwd_bytes`, the most either can hold; one longer would stop
at `ScopeTooLong` and be reported rather than widen the search to global.
The query text is the prompt field's, 128 bytes, cut on a character
boundary. Every query, scope or filter edit resets pagination and
selection. Only the newest request can replace visible results. Loading
results cannot be pasted or deleted. Each page records `utc_offset_min`, read
from the client's zone when the reply lands, so rows and day headings show
local time without the model reading a clock.

One resident page contains at most 100 executions
(`HistoryPaletteState.page_entries`); one reply may carry up to
`core.max_history_results`, 1000, which `telar history --limit` can ask for.
Repeated commands remain
separate executions so their timestamps, outcomes and output stay meaningful.
Up selects towards older/lower-ranked results and crosses the page boundary.
Down returns towards newer/better-ranked results. PgUp and PgDn request older
and newer pages. The title shows the loaded range and whether another page
exists, not a total count.

The first query returns a maximum-ID insertion boundary. Later pages carry that
boundary and an offset with deterministic timestamp/ID ordering, or fuzzy score
with timestamp/ID ties. Normal new inserts cannot shift the current search.
This is not a database snapshot: deleting or modifying matching rows from another
client can shift offsets. A confirmed local deletion starts a fresh query.
Byte-limited pages may be smaller than 100; navigating backwards can overlap the
previous page. This bounded one-page implementation replaces the review's
suggested two-page prefetch cache.

The fuzzy matcher scores the newest 10,000 executions in the selected scope
(`history.fuzzy_max_candidates`); older ones never match a fuzzy query. When
a page runs out inside that window while older executions exist, the runtime
reports the limit with the limit notice. Empty queries browse chronological
history without that candidate cap.
`client.history.match = "fts"` uses the existing indexed substring path instead.

## Inspection and bounds

Ctrl+O opens the inspector beside the list when at least 100 inner columns fit;
otherwise the inspector replaces the list. Ctrl+O or Escape returns to the list,
preserving query, scope and selection. A second Escape closes the browser.
PgUp and PgDn scroll wrapped detail while inspecting, bounded by its content.

`read_history_output` requests at most 64 KiB of captured output. The
`history_output` reply must match both request and selected entry. Changing
selection or closing inspection invalidates the visible request. The UI shows
loading, failure, missing output and truncated output explicitly. It does not
claim that missing output means capture was disabled.

The client allocates one storage block at startup: 768 KiB for long commands,
64 KiB for output and 64 KiB for the selected command fallback. It also keeps
100 fixed summaries with 512-byte command previews and 256-byte cwd previews.
Input, navigation and rendering allocate nothing. Preview truncation respects
UTF-8 codepoint boundaries. These previews never authorize an incomplete paste.

When page storage cannot retain a command, a bounded `query_history` with
`entry_id` retrieves that command, up to 64 KiB. A capture marked
`command_truncated` is never pasteable. Up to 128 outstanding request IDs are
tracked, including stale requests, so their eventual failures are consumed
without terminating the client. Queue saturation leaves an actionable local
error rather than a partial input batch.

## Submit and delete

Enter pastes the complete selected command. `client.history.enter = "run"`
inverts that default; Shift+Enter always performs the other action. Admission
checks complete command ownership and `model.to_runtime` capacity before closing the
prompt. Delivery then uses the ordinary pane-input operation because
focused input is unavailable while a prompt owns it.

Commands larger than one input message reserve all required 8192-byte chunks
before enqueueing any of them. Execution sends Enter after the bracketed-paste
terminator, not inside it. Terminal controls, invalid UTF-8 and embedded paste
terminators are rejected. Newlines and tabs require the child's bracketed-paste
mode so paste-only cannot become key input. Captured output is display-only and
passes through the cell renderer's control-byte sanitization.

Ctrl+D requests `delete_history` for one selected ID. The row disappears only
after the matching `history_pruned` acknowledgement and a fresh query. The GUI
also accepts ⌘⌫ on macOS.

Ctrl+C (⌘C in the GUI when the search field has no selection) copies the
complete selected command to the host clipboard through `HostEffects.clipboard`;
a truncated capture copies nothing and says why. Alt+Enter closes the browser
and lands on the pane the command ran in: a pane of the active workspace gets
local tab and pane focus, any other goes through the workspace handoff, whose
failure names a pane that no longer exists. The inspector says whether the pane
is open. Captured output is reduced to readable text when the reply lands
(`core.plainText` drops escape sequences and control bytes).

## Compatibility and verification

Pagination, exact command lookup and capture-truncation metadata change the IPC
encoding and its exact handshake fingerprint. Build and update client and runtime
together. There is no SQLite migration and no compatibility decoder. Do not stop
an existing runtime merely to preview the UI: it owns live PTYs.

Tests cover request/entry correlation, stale failures, complete-command ownership,
truncated captures, UTF-8 previews, paste framing, input batch admission, host
keyboard flows and pagination beyond 100 results under new insertions. SQLite
and schema golden tests cover the cross-process contract. These tests exercise
specific cases; the correctness argument depends on every mutation respecting
request identity, owned storage and the bounded queue admission policy.
