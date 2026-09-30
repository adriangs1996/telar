# Change review

The native GUI shows one **Review changes** action per visible pane with recorded
editions. It lives in the pane header, or the **±** button in the top bar when
the layout has no pane header. Empty panes have no review action. It reviews
changes that agent hooks observe in a terminal pane. The standalone `zig build run-widget` remains a fixture
bench for the presentation code; production code imports no experiment bridge.

## Ownership and data flow

```text
pane Pre/PostToolUse ──> telar hook ──> IPC ──> runtime review service
                                                              │
                                     immutable edition + durable comments
                                                              │
native Review changes <── change_review_snapshot <── query_change_review
         │
         └── change_review_command ──> save draft / save comment / submit
                                                              │
                      official hook additionalContext / cooperative CLI
```

The runtime owns edition identity, patch bytes, comments, draft state, review
revision and delivery state. The GUI owns selection, scroll, focus, native
composition and text being edited before its save is acknowledged. Closing a
window does not terminate the provider session or discard acknowledged drafts.

An edition is immutable. Its identity includes the provider conversation; pane
IDs and generations alone cannot authorize a command after the agent resumes a
different conversation. Queries and mutations retain that session identity.
Mutations also compare the acknowledged review revision. A stale response cannot
change a replacement view, and a rejected save keeps the local draft available.

Availability belongs to each pane generation and provider conversation, even
while the review is closed. The runtime republishes it when a client attaches;
changing conversations clears the previous conversation's availability.

New-edition notifications also refresh metadata for the edition already open. They do
not replace its diff or move its selection. **Older edit** and **Newer edit** are
explicit navigation operations.

The runtime's `change_review.start` translates IPC values and correlated
errors, and resolves the exact pane generation and provider conversation
before admitting a copied request. A bounded observation job calls the runtime
service. `change_review.finish` rechecks that authority before delivering the
result. The service never retains a pointer into a client or pane.

## Interaction

- `j/k` or arrows move through lines. `gg` / `G` and `Home` / `End` move to
  the first / last line of the open file.
- `Ctrl+u` / `Ctrl+d` move up / down half the visible diff height.
  `Ctrl+b` / `Ctrl+f` and Page Up / Page Down move a full page. These motions
  move the cursor with the viewport and account for wrapping and inline comments.
- `/` opens incremental, case-sensitive literal search in the open file.
  Matches use the active theme's colors. `Enter` retains the query; `n` / `N`
  visit the next / previous occurrence, wrapping at the file boundary. `Esc`
  while typing restores the previous query, selection and scroll. Search accepts
  at most 256 UTF-8 bytes, without line breaks; it does not interpret regexes.
- With no search query, `n/p` move between changes. The **Previous** and **Next**
  buttons keep that behavior while searching. `Esc` clears a retained query.
- `v` starts a line range. Selection stays inside one file, hunk and diff side.
  File/page motions and search extend the range within those same boundaries.
- `c` opens a comment for the selected line or range. The editor supports native
  UTF-8 input, IME, clipboard operations and accessibility.
- Draft changes are coalesced into runtime saves. **Save comment** or
  `Cmd/Ctrl+Enter` makes a draft ready to send.
- **Send review** sends saved comments together. The GUI requires all drafts to
  be saved or deleted first. Sending locks the submitted comments to that edition.
- **Review edition** records a review marker; it does not approve an agent tool
  request, execute a command, or send comments.
- `Esc` cancels composition/selection, folds a comment, or closes the review.
- A failed save retains the draft. **Refresh / retry** reloads the current review
  revision and explicitly retries the local changes.

The status distinguishes a save still in flight from one acknowledged by the
runtime. Bytes typed immediately before a client crash may not yet be durable.

## Capture and delivery contracts

Hooks capture bounded before/after samples for paths declared by the edit tool, with
the tool-call and conversation identity. The UI identifies the evidence source.
Concurrent writes between hook samples can be present in an observed snapshot;
that source is evidence of the observed file transition, not proof of authorship.

Automatic adapters currently cover Claude `Write`/`Edit` and Codex
`apply_patch`. Shell-generated edits are not attributed. Pi can use the
cooperative review commands; its queued extension does not provide a reliable
before-edit sample. See [agent hooks](agent-hooks.md) for registration and limits.

Panes receive feedback through the provider's official hook context or
`telar review feedback` followed by `telar review ack`. Telar does not paste
feedback into a pane's PTY.

Repeated submission of an already submitted edition does not recreate its
feedback. Hook delivery is at least once if its output succeeds but its
acknowledgment is lost. Feedback carries an identity so
cooperative consumers can deduplicate it.

## Budgets and failure behavior

File reads, JSON, Git diff generation, persistence and syntax parsing run on
observation workers. Native input and painting use bounded retained buffers.
Syntax highlighting uses the vendored Tree-sitter grammars and queries through
the existing Rust static library. Captures resolve to semantic syntax roles; the
active Telar theme supplies their colors, italics and weight. Bundled queries
are compiled lazily per language on the observation worker, before the source
parsing deadline begins. Theme changes do not require parsing the source again.

The review wire bounds a patch to 48 KiB, each source sample to 24 KiB, a comment
to 2 KiB and formatted feedback to 8 KiB. There are at most 32 comments per
edition. The view indexes at most 32 files and 1,024 numbered rows. Unsupported
or oversized content fails explicitly; it is not silently truncated into a
different review. One syntax job uses an inactive source slot; its completion is
adopted only after the preceding presentation releases its resources. The two
slots, each a source and one role per byte, are reserved when the window starts
and sized by the patch limit; the view borrows the visible slot's roles.

Syntax highlighting never refuses an edition. A job highlights at most 1,024
fragments (one side of one hunk; `syntax.job_fragments`) and starts no fragment
after one second (`syntax.job_ms`); a source larger than 256 KiB
(`syntax.source_bytes`, which the build asserts holds the patch limit) is not
highlighted. A job that reaches one of these keeps the roles it wrote, leaves
the rest in the plain syntax color and returns the limit with its edition; the
window's loop adopts the edition as usual and reports the limit. A job that
fails (a grammar, a malformed native result, memory) shows the whole edition
plain and logs why. Copying review code takes at most one patch and the clipboard's 1 MiB; a
longer selection copies the lines that fit and reports `ClipboardTooLarge`.

The service admits four observation jobs, at most one per client connection.
Availability discovery uses at most three slots, leaving one for review requests.
It caches 32 conversations and 16 editions per conversation; eligible cache
entries can be reloaded from disk. Unsent commented editions stay in memory.
Once all 16 are pinned, capture reports a capacity failure until reviews are
delivered or their comments are removed. Other editions move to separate archive
files and remain navigable and editable. Each conversation retains up to 4,096
edition identities within an 8 MiB storage quota. All conversations together use
a 256 MiB retained-storage quota. Saturation preserves existing editions and
appears in review status; it does not silently delete older reviews.

Before/after capture holds at most 32 pending paths per conversation. Unmatched
samples expire after ten minutes and are discarded when the owning pane
generation changes. Creation or deletion of an empty file currently has no
supported text hunk and is rejected as an unsupported patch.

Review storage lives in the runtime state directory's `change-reviews`
subdirectory. It stores source code and review text intentionally, as the data
being reviewed, rather than as generic traffic telemetry. Directories are private
to the account and files use owner-only permissions. Writes replace files
atomically; malformed existing data is rejected and preserved for diagnosis.
The manifest format is version 2. Reads validate the opened file descriptor,
permissions, owner, size, edition identities and comment anchors. This experiment's
earlier version 1 files are rejected with a storage-validation error.

## Verification

- `zig build test-client test-gui test-widget check-client-boundaries codestyle`
  covers correlated requests, retained drafts, native ownership and presentation.
- `zig build build-widget` followed by
  `python3 tools/gui_review_navigation.py zig-out/bin/run-widget /tmp/review-navigation`
  exercises Vim navigation, native UTF-8 search and range comments in the
  standalone fixture, records screenshots and closes its window. It starts
  neither a runtime nor a provider and makes no model calls.
- `python3 tools/test_review_runtime.py zig-out/bin/telar /tmp/review-hooks`
  exercises the real runtime and ordinary-pane hooks with a deterministic
  provider fixture, including restart, stale requests and feedback acknowledgments.
- Add `--provider claude` to exercise the Claude adapter.
