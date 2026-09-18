# Agent panes

The GUI creates a new agent tab with `prefix + a`. The tab belongs to the current
workspace and starts Codex in the focused pane's working directory. Normal
`prefix + c` still creates a terminal tab. Both kinds appear in tab navigation;
managed agents also enter the existing agent sidebar.

While a managed agent is working, the sidebar's third row shows the latest
root-turn message or tool detail from its conversation snapshot. The runtime
projects this into the same bounded `AgentSnapshotEntry.last_event` used by terminal
agents, so activity changes publish a sidebar revision without resetting the
working duration. Previous turns and child output cannot replace that line.
Before activity arrives, the row shows `Working`; when the turn settles, the
card returns to the workspace branch. Tracker regression tests cover activity
updates, completion, turn isolation and UTF-8 bounds.

The sidebar session title is independent of the tab label. Managed panes use
the same title tracker as terminal agents. When `runtime.agent_descriptions` is
configured, the first accepted composer message queues one title job through
the existing bounded generator. Multiline text is normalized as submitted text,
without applying terminal editing controls. A rejected or busy submission does
not consume this first-message capture. Scheduling does not depend on observing
an intermediate `working` snapshot, which may be coalesced with completion.

Codex's initial `thread.name` and root `thread/name/updated` notifications also
update that tracker. Names are owned and validated in the provider worker, then
published atomically with the matching conversation snapshot. The runtime applies
each metadata revision once, so later transcript updates cannot restore an older
name over a newer title. Child-thread names cannot rename the parent. Empty
provider names follow the existing title-clearing policy. Without a provider
name or configured title generator, the local placeholder remains visible.

The composer accepts text, multiline paste and native text input. Enter sends;
Shift+Enter inserts a newline. Send is available when Codex is ready, and Stop
interrupts an active turn. Command and file-change approvals expose the exact
pending request with Approve and Decline controls. Review full request opens
the complete request in a scrollable view.

The GUI folds intermediate commentary, reasoning, commands and delegated work
behind `Show agent work`. User messages and final responses stay visible, as do
system notices and messages whose provider phase is unknown. The header shows
the retained activity count and whether work is ongoing. Clicking it, activating
it from the keyboard or using accessibility invokes the local `toggle_work`
control. Opening the group reveals its rows and individual details; activities
skipped during folded history navigation are fetched again through the normal
history reader. Closing it restores the compact conversation without changing
pending approvals.

Expansion belongs to the GUI attachment and provider turn. Streaming and
history paging retain it, while a new turn or client starts folded. The GUI
registers selection and copy geometry only for exposed rows. `test-gui` covers
grouping, stale controls, reading anchors and page seams; `tools/gui_agent_messages.py`
exercises the disclosure, native copy and reconnect in a real window.

Agent controls use the same configured bindings as terminal panes, including
direct global shortcuts and prefixed sequences. Matching shortcuts run before
composer editing; unmatched keys retain their normal editor behavior. Open
menus and modal prompts retain keyboard capture. IME commits and pasted text
do not trigger bindings.

Pointer hover, including stationary motion emitted by macOS when releasing a
modifier, preserves the focused control and any pending prefix. Clicking or
dragging a selection in the composer still takes editing focus and cancels the
sequence.

GUI widget routing asks the shared router whether a key starts or continues a
binding. A partial sequence retains only its originating widget ID and generation.
On mismatch or timeout, held text returns to that live composer; a retired owner
consumes it. Physical repeats and releases retain their original owner even when
the action changes pane, tab or modal focus. This routing allocates no storage
beyond the existing bounded key tables and one optional widget identity.

The active pane also owns native editor focus. When a split or navigation focuses
a sibling terminal, widget routing and native text-context publication retire the
agent's editor focus before accepting more input. Frame delivery revalidates that
ownership, including frames prepared before the focus change. Pending composition
is cancelled; stale targeted text and held widget keys cannot reactivate the
agent. Fresh typing and paste follow the terminal's existing `pane_input` route.
The GUI interaction tests cover typing before, after and during frame delivery,
native composition, stale events, paste and navigation-key releases.

The composer offers the models and reasoning efforts returned by Codex's
`model/list`, plus Read only, Workspace and Full access choices. Its initial
selection comes from the effective thread settings when the catalog supports
them. If the configured model is absent, Telar selects the catalog's marked
default, or its first model when no default is marked, with a visible notice.
An unsupported configured effort falls back to that model's advertised default
with a notice. These are choices for the next turn. Changing a model selects
that model's advertised default effort. Selections belong to the client draft
and travel with its next prompt; they do not change global Codex configuration.
The footer uses retained cwd and workspace branch metadata.

## Commands and skills

Typing `/` at the beginning of the composer opens a filtered command list above
the input. Typing `$` at a word boundary opens the skill list. Each skill shows
its display name, description and Personal, Project, System, Admin or Plugin
scope. The menu keeps editor focus and uses the current theme.

| Command | Effect |
| --- | --- |
| `/clear` | Start a new conversation in this pane, retaining the old one until creation succeeds |
| `/rename <name>` | Rename the current conversation through `thread/name/set` |
| `/model` | Open the existing model selector |
| `/permissions` | Open the existing access selector |
| `/skills` | Open the skill selector |
| `/skill:<name>` in the selector | Insert the corresponding `$name` mention |

Up and Down navigate results. Tab inserts the selected entry. Enter or a click
selects a skill without sending the message, or executes a command. Selecting
`/rename` inserts the command and leaves the caret ready for the name. Escape
dismisses the list. At most eight rows are visible; navigation and scrolling
expose later results. Filtering preserves text surrounding a skill mention.
Stale row identities and native key targets cannot select a newer suggestion.

The provider worker requests `skills/list` for the pane's working directory and
refreshes it on `skills/changed`. It keeps only enabled skills and owns their
absolute paths. Client snapshots carry bounded display metadata. When a prompt
mentions an advertised `$name`, the worker adds the explicit `skill` input with
that name and path to `turn/start`, once per skill. This follows the
[Codex app-server skills protocol](https://learn.chatgpt.com/docs/app-server#skills).
The GUI does not read skill files. Catalog failures leave ordinary prompts and
commands available; incomplete catalogs show a notice. Requests exceeding the
provider output limit fail visibly without closing the session.

Conversation commands do not start model turns or seed automatic title
generation. A successful `/clear` retires client history and its pending queries,
preserves a newer draft, and retains the selected model and access settings.
Provider errors preserve the current conversation. Runtime and client must use
the same protocol version, now 57.

## Conversation and activity

Sent messages use a right-aligned bubble. Assistant messages use proportional
text with headings, lists, quotes, emphasis, inline code and fenced code blocks.
Completed responses expose Copy response, which copies the original Markdown.

Inline Markdown links display an accented, underlined label, including any inline
code or emphasis inside it. Hovering a visible label fragment shows the destination
in a tooltip; wrapping and scrolling use the painted text bounds. Local file paths
with line numbers and web URLs use the same presentation. Link hover keeps composer
focus, and the wheel continues scrolling the conversation over a label.

Supported syntax includes `[label](destination)`, optional titles, escaped
punctuation, balanced destination parentheses, destinations inside `<...>` and
HTTP(S) autolinks inside `<...>`. This is a bounded subset of
[CommonMark links](https://spec.commonmark.org/0.31.2/#links): reference definitions,
images and links spanning separate source lines remain unsupported. Code blocks
and code spans keep link syntax literal. Hover only displays the destination;
opening files or browsers is a separate interaction.

Tools appear as compact activity rows with their command, file summary or tool
name and actual lifecycle state. Expanding a row reveals its output or diff.
Dispatch rows identify delegated work; nested subagent cards retain their own
identity, task, latest result and status. Completing a dispatch does not complete
the child. A completed child turn is Idle, because the child can receive more
work. Provider errors, interruption and declined tools remain distinct states.
Reasoning rows contain only the provider's public summaries.

The header reflects the current activity. Visible running labels use a moving
highlight over cached glyphs. Completed, hidden and idle activity requests no
animation frames. Scrolling and expanded details belong to the GUI; streaming
updates preserve expansion by item identity. At most 128 disclosures are retained
across panes. Opening a detail anchors its delivered header against the next frame, even
when new output arrives before the click. Scroll changes commit only after the
frame is delivered; newer navigation supersedes an older anchor. Escape returns focus to the composer;
Page Up and Page Down work while a tool control has focus. Command/Ctrl+C copies
the focused activity's original text.

## Conversation selection

The native conversation owns a text selection separate from the terminal's
cell selection. Mouse hits use the grapheme positions of the font that painted
the delivered frame. Selection spans message blocks and expanded tool output.
Clipboard text follows the visible content: inline formatting and hidden link
destinations are omitted, while literal prompts and code keep their original
bytes. The existing whole-response copy control still copies the original
response.

The configurable `enter_copy_mode` action delegates agent panes to the native
conversation reader. Terminal panes keep their existing copy mode. Reader
focus consumes editing input instead of changing the composer. Native copy-mode
entry, active state and exit cross the existing host input port; common action
policy retires the mode before another action runs.

| Reader input | Effect |
| --- | --- |
| `prefix + [` or configured copy-mode binding | Focus the conversation cursor |
| Arrows / `h j k l` | Move through text |
| Home / End / `0` / `$` | Move to the line boundary |
| Page Up / Page Down | Move through the current reading window |
| `v` / Space, or Shift + movement | Select text |
| Command/Ctrl+C | Copy the selection |
| `y` / Enter | Copy, then leave after clipboard success |
| Command/Ctrl+A | Select the retained reading window |
| Escape / `q` | Return to the composer |

Selected clipboard text is limited to 64 KiB. A capacity or host clipboard
failure preserves the selection and reports the failure instead of copying a
partial result.

Composer clipboard requests retain their request ID, target, text revision and
selection range. A delayed paste cannot replace a newer edit or follow focus to
another pane. Cutting removes text only after clipboard success while the
original editor is still focused and unchanged.

Selection pins the current reading window. Preparation creates a bounded copy
of live text when needed; pointer and key input allocate nothing. New agent
output continues updating the live model, while history replies from before the
selection become stale. Scrolling within the pinned pages remains available.
At their boundary, the UI asks the user to clear the selection before loading
more messages. Leaving selection releases a snapshot created for selection;
an existing history reader retains its pages and can paginate again.

## Conversation history

Scrolling beyond the retained conversation requests an earlier page from Codex.
The client keeps at most two pages and replaces the page furthest from the
reading position as navigation continues. Each page has the same item and byte
bounds as a live snapshot. New provider output still updates the live state,
composer and approvals while the client reads older messages.

The GUI measures and scrolls exposed rows. At a history boundary, pages that
only extend an already folded work group are traversed automatically, keeping
the page with visible conversation in place. This scan runs after successful
frame delivery, with one request outstanding and at most 32 additional pages
per gesture. Selection, expanded work, a new visible group, failures and cursors
that stop advancing interrupt the scan. Opening a group whose middle pages were
skipped restores a contiguous reading window and reloads those activities.
`tools/gui_agent_scroll.py` exercises this with a native window and a paginated
provider fixture: one gesture reaches the prompt, the final response remains
copyable, and expanding then folding the group reloads the omitted work.

History queries use `query_agent_history`; `agent_history_page` is the final,
targeted reply. Request IDs, pane generations and navigation generations reject
obsolete responses. Provider turn IDs and item IDs together identify the shared
boundary between live messages and historical pages. Item IDs alone are not
unique across turns. Text larger than a page is split at UTF-8
boundaries and carries its original byte offset, so navigation can recover the
remaining text. A page never silently evicts another item to fit its byte limit.
Partial messages display their original text and expose Copy segment. Complete
messages retain Markdown, diagrams, links and Copy response.

The runtime reads history through a separate Codex app-server process. It
initializes the connection, checks `thread/read` without turns, then requests
`thread/items/list` with opaque cursors. The reader never starts or resumes a
thread or sends a prompt. Codex keeps the durable transcript; Telar does not copy
response bodies into its history database. A failed or timed-out history read
does not stop the live provider.

This path requires Codex's paginated thread storage. Legacy sessions and providers
without the history API return an explicit failure. Failed reads remain
retryable, without polling the provider on every rendered frame.

## Ownership and entrypoints

| Trigger | Client entrypoint | Wire request | Runtime owner |
| --- | --- | --- | --- |
| `prefix + a` | `agent_threads.create` and tab creation handlers | `create_tab` with kind `agent` | `CreateTabController`, `CreateTabHandler`, pane launcher |
| Composer edit | GUI widget routing, `AgentThreadHandler.edit` | none | client pane composer |
| Model, effort or access choice | `agent_threads.selectModel`, `selectEffort`, `selectAccess` | included in the next `agent_prompt` | client draft, then runtime/provider validation |
| Enter or Send | `agent_threads.submit` | `agent_prompt` | `AgentThreadController`, `AgentThreadHandler`, provider worker |
| `/` or `$` completion | `completions`, `CompletionState`, `CompletionMenu` | none | client draft and delivered widget identities |
| `/clear` or `/rename` | `completions.submit`, `agent_threads.submit` | `agent_prompt` | `Codex.runCommand`, provider response, retained snapshot |
| Skill catalog refresh | provider `skills/changed`, `skills/list` | `agent_thread_snapshot` | `SkillCatalog`, provider worker |
| Stop | `agent_threads.interrupt` | `agent_interrupt` | same runtime control path |
| Approve or Decline | `agent_threads.approve` | `agent_approval` | same runtime control path |
| Attach or reconnect | `agent_threads.query` | `query_agent_thread` | retained runtime snapshot |
| Scroll beyond the reading window | `agent_history` controller | `query_agent_history` / `agent_history_page` | bounded reader, per-client delivery |
| Provider output | provider worker, runtime change receiver | `agent_thread_snapshot` | client model, `ThreadView`, GUI `ThreadPane` |

The runtime pane owns either a PTY session or a managed agent session over
pipes. Agent panes do not start a shell or emulate app-server JSON as terminal
output. Their VT storage supplies the terminal client's availability message.

Codex owns its durable transcript. Telar retains a bounded snapshot in RAM for
rendering and reconnect. Detaching or killing the GUI leaves the agent working.
The runtime also retains its sidebar title and rebuilds it for reconnecting clients.
Closing the pane stops the provider and its descendants. Runtime checkpoints
preserve agent pane identity, location and conversation reference. Restart
launches a new app-server and resumes the saved conversation with explicit
workspace permissions and user approvals; clients fetch its history again.
Empty panes start new conversations. See [session checkpoint](session-checkpoint.md)
for validation, failed resume recovery and the `resume_agents` setting.

## Bounds and delivery

- At most 16 live agent processes run in one runtime. Temporary history readers
  have a separate limit of four.
- Each provider catalog contains at most 16 models and eight efforts per model.
  Model IDs and labels are bounded to 128 bytes; effort IDs to 32 bytes. Efforts
  are provider-supplied strings. Additional catalog pages produce a visible
  notice. Draft settings allocate only for agent panes with a valid catalog.
- A worker admits eight queued commands. Prompt delivery is copied and rejects
  a busy agent instead of accumulating future turns.
- Provider JSONL records retain at most 256 KiB, parsing storage is limited to
  2 MiB, and outgoing provider records to 64 KiB. Small records use the existing
  buffered read. A larger live record switches to `OutputFrame`, which streams
  through the JSON scanner and retains at most 8 KiB per output string plus an
  explicit truncation marker. Output fields include command stdout/stderr,
  aggregated output, text/deltas, diffs and tool data. The scanner validates
  discarded bytes and drains through the newline before reading the next record.
  Identifiers, command arguments and lifecycle metadata remain intact. Completed
  items and deltas carry the truncation flag into the transcript; approval review
  cannot mistake a preview for complete evidence. Truncated RPC requests and
  responses fail explicitly before application, as do oversized metadata and
  nesting beyond 64 containers. The projection adds one fixed 256 KiB scratch
  buffer and 256 bytes of scanner allocation storage per active read, with no
  allocation proportional to incoming output. Parsing and process I/O stay on
  the observation worker, independent of PTY input and output. Canceling the
  session cancels a pending read even while draining a large record.
- Each conversation snapshot retains at most 64 items, 48 KiB of text and
  16 KiB of typed activity metadata. A complete snapshot stays below 128 KiB.
  At most 16 child agents are tracked per provider. Truncation is visible. Approval descriptions have a separate 4 KiB limit.
- Skill catalogs retain at most 128 entries and 16 KiB of display text. Names and
  labels are limited to 128 bytes, descriptions to 256 bytes. The runtime owns
  one 1 KiB path slot per entry. Selector filtering uses fixed storage and does
  no filesystem work or allocation on the input path.
  Requests whose complete scope cannot fit fail before exposing an approval.
- History permits four concurrent readers per runtime and one outstanding
  page per client connection, including replies waiting for delivery. Each
  reader has a 15-second deadline, a 2 MiB response limit, 8 MiB of JSON parsing
  storage and 2 MiB of formatting storage. Pages and cursors are bounded;
  cursors hold at most 2 KiB. Larger provider items fail explicitly. Reader
  configuration is immutable and retained independently of the pane lifetime.
- Each client retains at most 16 history windows, each bounded to two pages and
  256 KiB. Inactive readers can be evicted; selected text remains pinned until
  selection ends.
- Native text selection stores at most 2,048 item rows, 4,096 visible fragments
  and 32,768 grapheme carets per frame. The lazily allocated double buffer stays
  below 2 MiB and publishes only after successful frame delivery. Saturation
  reports a copy failure rather than exporting incomplete selected text.
- The client composer holds 8 KiB of UTF-8 text. Its fixed buffer is allocated
  at pane creation; editing allocates nothing. Invalid UTF-8, NUL bytes, invalid
  native replacement ranges and oversized edits leave the draft unchanged.
- Markdown parsing borrows snapshot bytes synchronously, with eight inline scopes,
  32 bracket/parenthesis nesting levels and a linear lookahead budget. The GUI
  registers at most 64 visible link fragments per frame and reserves 64 target
  slots for ordinary controls. Extra fragments retain their visual style.
- Link hover owns at most 4 KiB of decoded destination text and uses no heap
  allocation. Escaped punctuation, numeric entities and `amp`, `quot`, `apos`,
  `lt`, `gt` are decoded; unknown named entities remain literal. Invalid UTF-8,
  controls and oversized destinations produce no tooltip. The tooltip wraps
  within the window and shows at most 12 lines, with an ellipsis for overflow.
- Queued prompts use existing client outbox byte slots. Acknowledgements clear
  only the exact submitted content revision and attachment. Later typing remains;
  moving the caret or changing selection does not preserve already sent text.
- A capacity-one wake queue coalesces provider changes. Each client maintains
  its own delivered snapshot revision and receives the latest retained state.
  Idle conversations need no client polling.

## Authority and failures

Controls identify the pane and its runtime generation. An approval also names
the pending approval ID. Native editor and control targets include the client
attachment generation. Conversation controls also resolve a stable item identity,
so evicting or reordering rows cannot activate a replacement. IME and clipboard
completions additionally validate the editor revision. Stale input cannot authorize a replacement request.

Message link targets retain item identity, source offsets, attachment generation,
runtime pane generation and snapshot revision, never borrowed message pointers.
Hover resolves only the delivered registry against its matching live or
historical snapshot.
The next frame also checks the prepared fragment bounds before painting the
tooltip, so replacement, scrolling, failed delivery and modal transitions cannot
reuse an obsolete destination. Idle hover has no animation or timer.

The initial Codex thread uses workspace-write permissions and explicit user
review of untrusted operations. Telar uses the installed Codex authentication.
Missing executables, login failures, malformed output, timeout and provider exit
produce visible errors. A queued prompt remains in the conversation even when
the provider fails after accepting it.

Command execution and file changes have native approval controls. Other
server-initiated interactions, including structured user questions and MCP
elicitation, currently receive an explicit unsupported-method response and a
visible notice. No unsupported request is automatically approved.

Approval details include requested write roots, additional permissions and the
referenced file changes. The adapter sends only the supported `accept` or
`decline` decision. It never substitutes a broader grant when `accept` is absent
from the provider's available decisions.

## Verification

### Large provider output

`Stream.zig` exercises multi-megabyte escaped output, following records, strict
history-reader limits, malformed discarded bytes, EOF and cancellation before
the newline. `OutputFrame.zig` checks every input boundary through UTF-8, JSON
escapes, keys, numbers and containers, plus truncation and metadata/depth limits.
`session_test.zig` drives a fake provider through a 4.2 MB command result,
approval, turn completion and another prompt. `codex_test.zig` verifies that
projected items remain explicitly incomplete and cannot authorize an operation
using truncated evidence.

### Commands and skill selectors

`python3 tools/gui_agent_completions.py zig-out/bin/telar /tmp/telar-completions`
opens an isolated native window with a fake provider. It saves command and skill
screenshots, filters and clicks a skill, renames the conversation, clears it,
then checks that the new thread receives the exact explicit skill path. No model
calls are made. GUI tests cover keyboard completion, held Enter, stale targets
and draft preservation. Provider tests cover disabled skills, cwd isolation,
refresh correlation, failed commands and oversized skill inputs. Wire tests
round-trip the maximum skill catalog with maximum transcript metadata.

### Resume an existing conversation

An unused, ready agent pane exposes **Resume conversation** in its header.
The existing composer menu supports pointer selection, arrows, Enter and Escape.
It shows up to 16 non-archived root conversations from the pane's exact working
directory, ordered by their provider update time. Names fall back to previews;
the directory appears below each entry. An empty list, a pending list and a
failed list have distinct labels. The listing is captured when the pane starts.
If more entries exist, the menu identifies the displayed set as the 16 most
recent conversations.

`Codex.receive` requests `thread/list` on the pane's observation worker. The
runtime owns the validated, immutable list and publishes it in
`AgentThreadSnapshot`. The list retains at most 16 identifiers of 128 bytes and
titles of 160 bytes. Listing uses the existing provider record and parsing
quotas. Listing failure does not prevent starting a new conversation.

The client sends `AgentResume` with the pane generation and selected index.
`AgentThreadController` translates it; `AgentThreadHandler` verifies that the
pane has no user turns and that another managed pane has not already claimed
the conversation. `Session.resumeConversation` reserves its identifier before
enqueueing the provider command, excluding concurrent prompts and resumes.
`Codex.command` sends `thread/resume` with explicit workspace permissions and
user approvals. The response must identify the selected conversation and its
working directory. A provider rejection leaves the unused conversation intact;
a missing response fails the pane after the provider startup timeout.

Successful resume publishes the existing identity and title. Each attached
client requests its latest history page once, through the existing bounded
history reader, without clearing its composer draft. Legacy conversations use
`thread/read` with turns and a disposable index of at most 4,096 items, under
the same 2 MiB response and 15-second reader limits. Their local cursors retain
thread, turn, item and UTF-8 fragment boundaries. A malformed or oversized
history fails explicitly; it never becomes an empty successful history.
Disconnecting the GUI leaves the resumed conversation in the runtime.

`python3 tools/gui_agent_resume.py zig-out/bin/telar /tmp/telar-resume-smoke`
uses a simulated provider to select a recent conversation in a real native
window, recover its history, preserve the draft, send a follow-up to the same
thread and reconnect. Screenshots and `result.json` record the outcome without
model calls. Protocol, provider, runtime authority, client and GUI tests cover
selection bounds, stale controls, duplicate claims, timeout, draft retention
and legacy history pagination.

Provider tests use a fake JSONL process and cover initialization, streaming,
approval identity, cancellation, EOF, timeouts, record boundaries and allocation
failure. Client tests cover new-tab identity, snapshot ownership, stale
generations, draft preservation and outbox ownership. GUI tests exercise
multiline text, native composition, creation from the composer, approvals and
small layouts. Protocol tests bind the new encodings to the handshake
fingerprint. An IPC integration test connects two clients, disconnects both
during a turn, reconnects to recover the conversation, and closes the pane to
verify that the provider process is reaped.

The same IPC test reads a 100-item history in both directions from two clients,
checks the exclusive boundary with live messages, and verifies that historical
queries leave the runtime's live conversation unchanged. Protocol tests cover
cursor bounds, malformed navigation generations and owned text fragments.

On macOS, `python3 tools/gui_agent_lifecycle.py zig-out/bin/telar /tmp/telar-agent-smoke`
exercises the native GUI with an isolated runtime and a simulated Codex process.
It checks `prefix + a`, multiline submission, sidebar membership, completion
while detached and reconnection without a second provider process. The output
directory contains screenshots and `result.json`; the test makes no model calls.

`python3 tools/gui_agent_messages.py zig-out/bin/telar /tmp/telar-message-smoke`
exercises public reasoning summaries, command output, file changes, MCP tools,
dispatch and independent child turns with a simulated provider. The native
controls expand output and copy original Markdown; reconnection reuses the same
provider. It captures each lifecycle stage without making model calls.

`python3 tools/gui_agent_bindings.py zig-out/bin/telar /tmp/telar-binding-smoke`
loads an isolated keymap and checks native Ctrl+R history access and Alt+N
sidebar resizing while the composer has focus. Escape restores editing and
the complete draft survives both shortcuts. The simulated provider receives
no turn request. GUI regressions also cover pane navigation, prefixed actions
from conversation controls, modal capture, stale native targets, key releases
after focus changes, and replay of unmatched or expired sequences.

`python3 tools/gui_agent_links.py zig-out/bin/telar /tmp/telar-link-smoke`
checks native file and web link labels, fragments across multiple display lines,
and exact copying of the original Markdown. It captures tooltip hover and
departure states for visual review using a simulated provider. GUI regressions
also cover failed frame delivery, snapshot replacement, modal capture, wheel
input over links, clipping, quota exhaustion and allocation-free cache replay.

`python3 tools/gui_agent_titles.py zig-out/bin/telar /tmp/telar-title-smoke`
uses an isolated runtime, a simulated provider and a deterministic title command
to check that the first multiline prompt generates one title and reconnecting
the GUI preserves it. The provider IPC integration also checks initial names,
root rename notifications, unrelated-thread rejection and title recovery after
all clients detach.

See [ADR 0015](../adr/0015-own-agent-panes-in-the-runtime.md) for the
GUI-only scope and conversation ownership decision. See
[Codex integration validation](codex-validation.md) for the pinned T3 comparison,
permission mappings and the separate direct-protocol and GUI evidence.
