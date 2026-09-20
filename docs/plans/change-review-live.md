# Live change-review experiment

This extends the `run-widget` experiment with one authenticated Codex session.
An independent Python process owns the session and retained review. Closing the
window does not terminate the agent or delete submitted comments. Draft comments
still belong to the prototype window until the user explicitly sends the review. This is an
observation worker prototype; it does not integrate the feature into Telar's
production runtime, pane hooks, history database or client IPC.

## Reproduction

Requires the installed authenticated Codex CLI and the compiled review widget.
The `start` command makes a real model call; submitting the review makes another.
It inherits the configured model returned by `thread/start`, validates it against
`model/list`, and uses its supported low effort when available. It never changes
Codex's global configuration, hook trust or credentials.

```sh
python3 tools/review_live.py start /tmp/telar-live-review-01
```

Open the native viewer from the worktree after the socket becomes ready:

```sh
TELAR_REVIEW_SOCKET=/tmp/telar-live-review-01/review.sock zig-out/bin/run-widget gui
```

Select the added lines with `j`, `j`, `j`, `v`, `j`, then `c`. Save the comment
with Cmd/Ctrl+Enter and choose **Send review**. The worker delivers saved comments
as one copied request; editing a local comment afterward cannot mutate that
request. A correction announces edition 2 without replacing the current editor,
selection or source. Open edition 2 explicitly to inspect it.

To reproduce the automated native round trip, including closing the window during
correction, reconnecting and checking the resulting function:

```sh
zig build build-widget test-widget codestyle
python3 tools/gui_review_live.py zig-out/bin/run-widget /tmp/telar-review-new-run
```

The harness closes its windows and stops the coordinator it starts. `--existing`
uses an already running coordinator and leaves its lifecycle with the caller.
It writes `result.json`, exact submissions, native action logs and screenshots.

The output directory must be new and short enough for a Unix-domain socket. After
the first edit, the worker publishes `review.sock`. The workspace contains only
`slug.py`. The first turn changes its return statement into two lines that
lowercase the label and replace individual spaces with hyphens. The review can
select after-lines 3–4 and ask the same session to trim and collapse whitespace,
including tabs. `slugify("  Café  Mundo\t ") == "café-mundo"` checks that correction.

A read-only inspection does not call a model:

```sh
python3 tools/review_live.py load /tmp/telar-live-review-01/review.sock
```

Stop the foreground worker with Ctrl-C, or send SIGTERM to the PID recorded in
`coordinator.pid`. Its `finally` block closes the socket and reaps the app-server
process group. Artifacts remain for inspection. A stopped worker can resume its retained session
without repeating the initial model turn:

```sh
python3 tools/review_live.py start /tmp/telar-live-review-01 --resume-existing
```

The worker validates retained patches and restores submitted comments and review
state. A submission left dispatching at shutdown becomes an explicit uncertain
failure; it never automatically retries a possibly accepted model turn.

## Local bridge contract

The owner-only Unix socket carries one request and one response per connection.
Each message starts with a little-endian unsigned 32-bit JSON byte length, capped
at 256 KiB. Schema version is 1. Loading uses `{ "schema": 1, "action": "load" }`.
Submission uses:

```json
{
  "schema": 1,
  "action": "submit",
  "request_id": "review-1",
  "revision_id": "retained revision SHA-256 identity",
  "comments": [
    {
      "file": "slug.py",
      "side": "after",
      "first_line": 3,
      "last_line": 4,
      "body": "Trim and collapse whitespace, including tabs; preserve lowercase."
    }
  ]
}
```

Responses contain `schema`, `session_id`, `revisions: [{id, patch}]`, submitted
`comments`, and `status` (`reviewable`, `working`, `complete`, or `error`). Errors include
an `error` string capped at 256 UTF-8 bytes. The GUI does not transfer row indices:
line numbers are one-based, inclusive, and identify the before or after source.
A `load` request remains immediate during correction. A `{ "schema": 1,
"action": "wait" }` request waits on a condition until the correction completes,
or returns the current working snapshot after 150 seconds. The socket service
accepts at most four concurrent requests, and the review lock prevents concurrent
submissions from dispatching duplicate turns.

Only one review may be submitted. Exact retries return the retained result and
never dispatch another model turn. Reusing an ID with changed content fails.
The request is persisted before dispatch; timeout/disconnection after dispatch
records uncertain delivery and forbids an automatic retry. A changed current
source hash, foreign revision/file, invalid range, empty body, oversized body,
or unsupported side fails before calling the model.

## Capture and ownership

The worker retains full before/after source snapshots around each completed turn
and constructs a full-context unified diff with Python's standard `difflib`.
The provider must also report successful completed `fileChange` items for the
same path. The worker replays their patches in order with `git apply` on an
isolated copy of the original source, then compares the resulting bytes with the
captured source. Thread, turn, item IDs and provider patches are stored as
evidence. Failed edit attempts are retained as diagnostics, and only successful
patches are replayed.
The second diff compares the first edited snapshot with the corrected snapshot.
It is not recomputed against an unrelated Git working tree.

These are **turn snapshots in a controlled single-writer workspace**, not exact
snapshots for every individual tool call. Provider evidence identifies a file
edit; this experiment does not prove attribution against concurrent writers or
capture shell-based writes without a `fileChange` event. The current-source hash
check rejects a detected edit before dispatch. Preventing another writer from
racing that check requires the eventual runtime's workspace/snapshot contract.

`revision-0.json` and `revision-1.json` retain source snapshots, hashes, provider
evidence and patches. `submission.json` retains the original structured review
and dispatch outcome; `feedback.txt` shows exactly what was sent. `state.json`
retains the response presented to reconnecting clients. These files live outside
the agent's writable workspace, in a mode-0700 experiment directory.

The agent uses workspace-write sandboxing, never approvals, and no network
access for its tools. This does not prevent the CLI's authenticated model
connection. No broader sandbox or hook-trust bypass is requested. The worker
accepts at most two editions, one file, 480 source lines per snapshot, 48 KiB
per patch, 32 comments and 2048 UTF-8 bytes per comment. Provider turns have a
120-second deadline, and both provider frames and bridge frames are bounded.

## Contract proof

```sh
python3 -m unittest discover -s tools -p test_review_live.py -v
```

These tests do not call a model. They verify adjacent snapshot diffs, retained
session/item evidence, exact range and feedback serialization, stale content
rejection, duplicate suppression, uncertain delivery, before/after line bounds,
foreign evidence rejection, ordered patch replay, concurrent loading/waiting and
duplicate submissions, safe restore, symlink and byte limits, and bridge framing. Native
and authenticated evidence must be recorded separately by the live harness.

## Observed authenticated run

On 2026-09-19, the native run against the isolated workspace at
`/tmp/telar-live-review-01` completed the full sequence. The first edit lowercased
a label and replaced individual spaces. Native visual selection commented on
new lines 3–4; Send review delivered the exact multiline Unicode comment to the
same provider thread. The correction replaced `normalized.replace(" ", "-")`
with `"-".join(normalized.split())`.

The first window closed while the coordinator kept the correction alive. A new
window recovered the submitted comment, waited for the result, displayed edition
2 and reopened the original edition-1 comment with its exact text. Four behavior
checks covered surrounding/repeated whitespace, tabs/newlines, lowercase,
Unicode and empty input. An exact duplicate submission returned the same result
without another turn; a foreign revision ID was rejected. Provider patches were
replayed successfully against the retained source before accepting corrections.

Evidence is retained in `/tmp/telar-live-review-01/result.json`, `submission.json`,
`feedback.txt`, both revision records, and the `live-*.png` screenshots. This proves
one real review/correction round trip. It does not establish production runtime
integration, arbitrary terminal-pane hooks, concurrent-writer attribution or
persistence of unsent drafts.
