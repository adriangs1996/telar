# Path picker

`prefix+f` opens a fuzzy finder over the files and directories under the
focused pane's working directory. It sits at the pane's cursor, with the
search field on the edge next to it. Enter pastes the chosen path into the
pane; nothing runs.

## Ownership

The runtime owns the index: the pane working directory is a runtime value
and, with `--remote`, the filesystem the path must exist on is the
runtime's. The client owns the root being browsed, the page of matches, the
selection and the placement. Closing the client frees its index.

```text
path_picker.enter (client)
  -> find_paths { root, query, kind, limit, refresh }
  -> client_request.receive -> path_picker.request (runtime loop)
       refresh or new root -> path_index_build.run   (observation worker)
       query               -> PathQuery.run          (observation worker)
  -> path_results { root, scanned, complete, truncated, matches }
  -> runtime_messages -> path_picker.receive -> PathPickerState (Version.path_picker)
  -> PathPicker (window overlay)
Enter -> path_picker.insert -> pane_input.pasteText -> pane input
```

## Index

`src/backend/paths/path_index_build.zig` fills one `PathIndex` per client.
Inside a git work tree it streams `git ls-files -z --cached --others
--exclude-standard`, so `.gitignore` holds exactly, and adds each file's
directories the first time they appear. Elsewhere it walks breadth-first,
skipping hidden entries and `node_modules`, `zig-out`, `target` and
`__pycache__`. Symlinks are listed, never followed. Paths that are not
UTF-8, carry control bytes or exceed 1024 bytes are skipped, so every path
the wire carries can be pasted.

Storage is reserved once when the client first opens the picker: 512 Ki
entries and 32 MiB of path bytes, mapped straight from the system so only
the pages a build writes become resident, in every build mode, plus a 512
KiB alignment matrix. A query over a full index takes about 17 ms on its
worker in a release build (`zig build test-isolation`). An index that reaches either bound
reports `truncated`, keeps what it listed and `finishBuild` names the bound
(`paths.max_entries` or `paths.max_bytes`). Four indexes live at once; a
fifth client takes the slot of the idle index used longest ago, whose owner
rebuilds on its next request, and only when workers hold all four is the
request refused with `resource_limit`, naming `paths.indexes_capacity`. The builder appends into that
storage and publishes the entry count with release ordering every 1024
entries; a query reads the published prefix at the same time, so the first
keystrokes get answers while a large tree is still being walked. Replies
taken before the build finished carry `complete = false`; the runtime runs
the newest query again once the build completes.

A `refresh` request, sent when the picker opens or its root changes,
rebuilds the index. A running build is cancelled first and the rebuild
starts when no worker holds the index. At most four clients hold an index at
once; a fifth gets `resource_limit`.

## Query

The loop keeps only the newest query per client and runs one query worker
at a time. `path_ranking.rank` scores every published entry with
`lib/fuzzymatch`, fzy's alignment in integers: matches after `/`, `-`, `_`,
`.` or at a lowercase-to-uppercase step, and consecutive runs, earn more;
every skipped byte costs. A match in the file name therefore outranks one
spread across directories. Ties go to the shorter path, then bytes. An empty
query browses: shallow entries first, directories before files, then bytes.

The reply holds at most 50 matches. Each carries the byte offset of every
query byte from the alignment that ranked it, so the highlight is exactly
what scored the row.

## Client

`PathPickerState` keeps the pane it inserts into, the pane's directory when
it opened (the anchor), the root, and a page of at most 50 matches within
50 KiB of path bytes, the longest page the runtime may send, so no match of
a reply is left out. Only the newest request id replaces the page, and only
for the current root. A ring of the last 32 ids recognises late failures of
older requests; the newest one's failure shows in the footer.

Keys: Up and Down, or Ctrl+K and Ctrl+J, move the selection the way the rows
run on screen: a picker opened above the cursor lists its best match at the
bottom, so there Up moves to worse matches (`path_picker.orient` reads the
placement from the model's cached layout). Tab browses the selected directory and
Shift+Tab the root's parent, both clearing the query; Enter pastes; Alt+Enter
and Shift+Enter paste the absolute path; Escape closes. A pointer press on a
row chooses it.

A path inside the anchor is pasted relative to it; any other path, or any
path with Alt+Enter, is pasted absolute. A word with characters outside
`[A-Za-z0-9_./+@%,:-]` is single-quoted, and a leading `-` becomes `./-`.
The paste goes through the same bracketed-paste delivery as the history
palette, after the prompt closes.

## Presentation

`path_picker_placement.place` puts the picker under the cursor, or above it
when the rows below do not fit; the window's `PathPicker` overlay uses it. The field is
always the row next to the cursor and the key hints the far row; flipped,
the best match sits just above the field. `PathLabel` lays out each row:
the directory muted, the file name plain, matched characters in the accent,
and a path too wide loses the middle of its directory to `…` while the file
name stays whole.

## Validation

- `lib/fuzzymatch/scoring.zig`: ranking order, bounds and walked-back positions.
- `src/core/schema/messages/paths.zig` and the golden corpus: codec bounds,
  control bytes, directory suffixes and rising positions.
- `src/backend/paths/`: index bounds, git and walk builds, cancellation,
  ranking and reply copies.
- `src/model/state/PathPickerState.zig`, `PathLabel.zig`,
  `path_picker_placement.zig`: stale replies, late failures, row layout and
  placement.
- `src/client/input/path_picker.zig`: relative, absolute and quoted pastes.
- `src/client_tests/path_picker.zig`: open, browse in and out,
  type, paste, stale reply and failure through the real client outbox.
- `src/gui/tests/path_picker.zig`: bounds on every host size, row hits and
  scrolling.
