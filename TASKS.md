# TASKS: prompt editor, Tab completion and command history

Bugs found by an audit of telar's prompt editor (telar mode), its Tab completion, the
runtime that serves completions, and the Ctrl+R history. Each task names where the bug
lives, what goes wrong, what should happen and the fix proposed. Line numbers are from
`main` at e99f519a7 and may have drifted.

## How to work through this file

- Read `CLAUDE.md`, `docs/code-style.md`, and for any new protocol request or field
  `docs/build/recipes.md`, before changing code.
- Work top to bottom, one task at a time. Tasks marked "with Tn" are one change: do them
  together.
- For each task:
  1. Confirm the bug first, with a regression test that fails, placed where
     `tools/check-cpp-modules.py` says it belongs. If the code shows it is not a bug,
     mark it `[~]` with one line of why, and move on.
  2. Fix it with the smallest change that follows the proposal. Reuse what exists
     (`runtime::utf8Prefix`, `GraphemeCursor`, `completionContext`, ...). No scope creep.
  3. Build and run only the touched domain: `just domain-test <label>` (one ctest at a
     time per build tree), `just gui-case <case>` for a window case, and
     `python3 tools/check-cpp-modules.py` when modules change.
  4. Tick the box here and commit code, test and this file together: one commit per task,
     message in English, imperative, saying what the change does. No `Co-Authored-By` or
     other model signature.
- When a proposal turns out wrong or needs a product decision not settled here, write the
  decision you took under the task (one or two lines) and continue. Do not stop the run for
  it.
- Never push, merge or rebase onto `main`. Leave the branch for review.

Legend: `[ ]` todo, `[x]` done, `[~]` not a bug / dropped (with reason).

---

## P0: crashes and lost work

- [x] **T1 (C14). A completion reply that breaks the wire schema kills the runtime.**
  `src/runtime/core/runtime/runtime.cpp:3245-3266` `deliverWords` sends without `try`; the
  exception reaches `main` and every pane dies. Triggers: `words.cpp:737` cuts descriptions
  with `substr(0, 256)` in the middle of a UTF-8 sequence; `expand()` (`words.cpp:188-242`)
  caps each alias step at 256 bytes but not the total, which overflows `DisplayText16<256>`;
  `ResponseQueueFull`.
  Expected: an encoding failure affects only that request.
  Fix: catch in `deliverWords` and answer `RequestFailed`, as `deliverBackgroundReply` does
  for its replies; cut descriptions with `runtime::utf8Prefix`; drop (or cap) an alias
  expansion whose total exceeds the field. Tests for both triggers.

- [x] **T2 (E20). A command the shell cannot receive is wiped before it is checked.**
  `src/gui/features/prompt/prompt-line.cpp:~470` `Line::submit` copies to `delivery_`,
  remembers and clears the editor, then `application-prompt.cpp:145` validates with
  `HistoryText::validate` and throws (multiline/tab without bracketed paste, C1 controls,
  over 64 KiB while `Text::capacity` is 256 KiB). The `answer` path does the same with
  `bracketed=false`. The comment in `prompt_controller.cpp` ("stays in the editor") is false.
  Expected: when it cannot be sent the text stays in the editor and the error shows.
  Fix: two phases. `Line::submit` prepares `delivery_` without clearing; `deliver` validates
  and sends, and only on success calls a new `committed(line)` that clears and remembers.
  Make the editor's limit match `HistoryText::maximum_bytes`, and drop C1 controls in
  `insert()` (`prompt.cpp:~252`).

- [x] **T3 (E19). On macOS every character typed with Option is swallowed.**
  `src/gui/ui/app/panes/terminal/prompt/prompt_keys.hpp:30-37` replaces the character with
  the base key and drops the text when Alt is held; `Editor::meta` returns `unhandled`, the
  line returns `ignored` and `PromptController::key` reports it taken. Spanish layout:
  Option+2 `@`, Option+1 `|`, Option+º `\`, `[ ] { } ~ #` cannot be typed.
  Expected: Option+key that produces a printable character writes it; Option acts as Meta
  only when the user asks for it.
  Fix: when Alt is held and `event.text()` is printable and differs from the base key,
  treat it as a plain character without Alt. Add `prompt.macos_option_as_alt` (default
  off) to the configuration for users who want Meta. Check that `NativeKeyAdapter` applies
  the same rule for the terminal.
  Decision: the rule lives in `KeyAdapter::terminalKey` (macOS convention only), so the
  terminal and the editor share it; `client.prompt.macos_option_as_alt` governs both.

- [x] **T4 (H4). The shell integration token is stored in captured output.**
  `src/runtime/terminal/command_capture/tracker/tracker.cpp:1328-1342` `afterOutput` appends
  the bytes before `zones_.scan`, so the `133;D;…;telar=<token>` mark (and the next `A`) end
  in `command_output.content`, served by `ReadHistoryOutput`.
  Expected: stored output holds no integration marks and never the token.
  Fix: append only the bytes before the start of the mark that completes the command (the
  zone scanner knows its offset), or filter OSC 133/6973 when appending to `output_`. Add a
  migration that strips the marks from outputs already stored.
  Done both: the relay cuts the output at the end of the mark that completes the command,
  and `IntegrationMarkFilter` (lib/base/history) drops OSC 133/6973, also the C mark inside
  the output. Schema version 6 strips them from stored outputs.

## P1: Tab completion (GUI and runtime)

- [x] **T5 (C1). When the spec does not accept the line, Tab offers nothing, not even files.**
  `src/gui/features/prompt/prompt-completion.cpp:105` returns empty for any status other
  than `valid`. `lib/ebnf/specs/git.ebnf` models only 15 subcommands, so `git sh<Tab>`,
  `git reset fi<Tab>`, `git rm <Tab>`, `git worktree …<Tab>` complete nothing.
  Expected: an unmatched spec falls back to files, as zsh and fish fall back to `_files`.
  Fix: on `invalid` or `unknown`, return the `"file"` provider. Add the common git
  subcommands that are missing (show, reset, rm, mv, tag, worktree, cherry-pick, revert,
  remote, clone, blame, bisect, clean, grep, config), generic arguments are enough
  (`{ @ref | @file }`).

- [x] **T6 (C2, with C3, C6, C7). Tab's paths come from a recursive fuzzy search.**
  `FindPaths` is the path picker's search: recursive, fuzzy, server-side `limit` 50 that
  `truncated` does not report (`query_task.cppm:265,294`); the GUI then keeps only direct
  children that start with the query (`prompt.cpp:823`). Deeper matches crowd out direct
  children (a child `main-application-config.yaml` with 60 `dN/main.c`: `ma<Tab>` returns
  50 results and not the child); an empty query in a directory with 50 or more
  subdirectories returns only directories. Inside a repo it uses `git ls-files` (no `.env`,
  no `build/`); outside it skips every dotfile and `node_modules`/`target` even as direct
  children; symlinks to directories count as files (`AT_SYMLINK_NOFOLLOW`).
  C3: `~/` and `$VAR` are not expanded: `~/Doc<Tab>` searches `<cwd>/~`
  (`prompt.cpp:640`) and the runtime answers "Path root is not readable".
  C6: executables named by a path (`./gradlew`, `bin/rails`) do not complete: at command
  position only the `command` provider is asked.
  Expected: Tab lists every direct child of the directory typed that starts with what was
  typed, sorted, with `truncated` when it cuts. Dotfiles only when the typed name starts
  with `.`; ignored files do appear; a symlink to a directory is a directory and gets `/`.
  `~/Doc<Tab>` completes under `$HOME` and the line keeps `~/`. `./gra<Tab>` gives
  `./gradlew`.
  Fix: add `CompletionProvider::path` to `CompleteWords` (it carries `pane_id`). The runtime
  reads one directory (`readdir`), resolved against the pane's cwd, expands `~` and `~user`,
  filters by prefix, takes the type with `stat` (following links), sorts, applies the
  limit and sets `truncated`. In the GUI, `askPaths` and `ask()` use it, the read directory
  is kept apart from the text written back, and at command position a partial with `/`
  asks for paths (executables and directories). `$VAR` is expanded only if the runtime
  knows the pane's environment; otherwise nothing completes. Keep `FindPaths` for the
  picker.
  Decision: the providers are `path`, `directory` and `executable`, new values of
  `CompletionProvider`, so the schema is cqp00012; against an older runtime Tab keeps
  searching with `FindPaths`. The runtime does not know the pane's environment, so `$VAR`
  completes nothing.

- [x] **T7 (C4). A word with escapes or quotes never completes.**
  `prompt-line.cpp:213` and `:426` filter the answers with the raw typed text (`My\ Do`,
  `"src/fo`) against unquoted choices (`My Docs/`); nothing is left and the menu closes.
  Expected: `cd My\ Do<Tab>` gives `cd My\ Documents/`; `cat "Some fi<Tab>` gives
  `cat "Some file.txt" `.
  Fix: filter with the unquoted prefix the lexer computes (`completionContext`) in
  `Line::receive` and `refine`. On accept, escape only the added part, and when the word
  opened a quote close it instead of backslash-escaping.

- [x] **T8 (C5). Remote (ssh) panes complete nothing.**
  `src/gui/application/application-prompt.cpp:95` `asks = ready && !remote` also stops the
  spec from being asked, so not even the spec's literals appear, although the comment in
  `plan()` says they should.
  Expected: in ssh the spec's subcommands and flags complete; files do not (they are on the
  remote host).
  Fix: ask the spec whenever the session is ready; ask providers and paths only when the
  pane is not remote.

- [x] **T9 (C8). The 1024 cap drops builtins, aliases and functions.**
  `src/runtime/terminal/shell_integration/words/words.cpp:732` caps on insert, and PATH is
  read first (`:746`), builtins and names after (`:747-749`). With 1100 executables and an
  empty prefix `cd`, `gst`, `myfunc` are missing; the 256 returned are the first of an
  arbitrary 1024.
  Expected: aliases, functions and builtins are always there; the cap applies to the final
  sorted result.
  Fix: insert the shell's names and builtins first, then PATH; or collect, dedupe, sort and
  cut at the end.

- [x] **T10 (C9). Options ending in `=` get a space after them.**
  `prompt-line.cpp:349` `accept()` always appends a space unless the choice is a directory:
  `--git-dir=`, `--color=`, `--track=` become `--git-dir= `.
  Expected: the option is written joined, the caret stays for the value, and the value
  completes.
  Fix: mark `Choice` as joined when the candidate is a spec option followed by `~` (the
  matcher knows) and skip the space for it.

- [x] **T11 (C10). Requests dropped without an answer hang Tab.**
  `words.cpp:914` returns silently when a client has 4 requests waiting. A dropped
  `RequestCommandSpec` leaves the GUI's spec `pending`, so Tab does nothing for that command
  until the shell runs another; a dropped completion leaves the menu at "…".
  Expected: every request gets an answer, even if empty or an error.
  Fix: fail the client's oldest waiting request with `RequestFailed{resource_limit}` and
  queue the new one. The GUI already handles `fail`.

- [x] **T12 (C11). The branch provider lists only local branches and runs a full status.**
  `git.cpp:237-275` reads only `refs/heads` and packed-refs; `words.cpp:756/760/766` call
  `git_.read()`, which runs `readChanges()` and `readDivergence()` (`git.cpp:426-427`).
  Expected: `checkout`/`switch` offer local and remote branches (`origin/x`, and `x` when it
  exists only on a remote); `merge`/`rebase` also offer tags. No working tree scan on Tab.
  Fix: read `refs/remotes` and `refs/tags` too (loose and packed); split
  `StatusReader::read` into `refs()` and `status()` and use `refs()` for the branch,
  remote and stash providers.
  Decision: `read()` stays (refs and status) and `refs()` joins it. Tags come through a
  new `reference` provider for a spec's `@ref`, in the same cqp00012; merge and rebase now
  take `@ref`, so `switch` is not offered tags.

- [x] **T13 (C12). A `#`-only line in a justfile empties the recipe list.**
  `words.cpp:328` `line.substr(line.find_first_not_of('#'))` throws on `npos`; `observe`
  catches and clears the words.
  Expected: empty comment lines are skipped.
  Fix: check `npos` before `substr`. Test with `#` and `####`.

- [x] **T14 (C13). `ssh_host` ignores `Include`.**
  `sshHosts` reads only `~/.ssh/config`.
  Expected: hosts from included files appear too.
  Fix: follow `Include` with `glob(3)`, relative to `~/.ssh`, depth at most 16 as ssh does,
  through the existing `readSmall`; skip `Host` patterns with wildcards.

- [x] **T15 (C minor). Small completion fixes.**
  - Commands from history at command position take the raw first word (`FOO=1`, `sudo`):
    extract the command word with the lexer, as `learn()` does.
  - `sudo`, `env`, `time` do not complete the command after them: in `completionContext`, a
    fixed list of wrappers (`sudo env time nohup nice exec command`) moves the command word
    to the next non-option word.
  - Names over 64 bytes never complete (`longest_name`): with the provider of T6 use
    `NAME_MAX` (255).
  The third needed nothing more: T6's providers bound the partial by the 256 bytes
  CompleteWords carries, so a name up to NAME_MAX completes; `longest_name` stays for the
  older runtime's FindPaths and for spec names.

## P1: history and the editor

- [x] **T16 (E15). Up in a new pane does nothing.**
  `prompt-line.cpp` `travel()` walks only `recent_`: what this pane sent in this GUI
  session.
  Expected: Up recalls this pane's commands first, then the global history, as fish or zsh
  with `share_history`.
  Fix: pass the `History` that `press` already has to `travel()`; past `recent_`, continue
  through `state.history` skipping duplicates. Optional, as fish: with text typed, Up
  filters by that prefix.
  The optional prefix filter is left out.

- [x] **T17 (E16). Ghost suggestions can stay unloaded forever.**
  `prompt.cpp:870` `failAll` and `prompt::fail` never reset `history_request`, so after a
  failed history query (or a disconnect while it is in flight) `historyAsked()` stays true.
  Expected: a failed or lost query is asked again.
  Fix: reset `history_request` in `prompt::fail` when the id matches and in `failAll`; on
  reconnect call `requestHistory` when the history is empty. See T27 for the runtime cause.

- [x] **T18 (E17). Commands the runtime filters as secrets are still suggested.**
  `remember()` in the GUI ignores `history_filters` (`secrets_filter`, `command_filters`).
  Expected: what the runtime does not store is not suggested either.
  Fix: apply the same filters in `remember()`. Their types are in `lib/config`; if the
  matching logic lives in the runtime, move it to `lib` so both share it.
  The logic already lives in `lib/config` (`HistoryFilters::allowsPane`); the window reads
  `runtime.history` of its own configuration with the new `readHistoryFilters`. A runtime on
  another machine keeps filtering by its own configuration.

- [x] **T19 (E18). Pasting from Ctrl+R does not reset Up/Down.**
  `prompt::write` (`prompt.cpp:267`) keeps `history_index_`; a later Down restores an old
  draft over the pasted command.
  Expected: after a paste, Up/Down start from the end.
  Fix: reset `history_index_` and close the menu in `write`.

- [x] **T20 (E21). Answers to a running program go through the shell's completeness check.**
  `Line::submit` tests `incomplete` before the `running`/`answering_` branch: `O'Brien`⏎ in
  answer mode inserts a newline.
  Expected: in answer mode Enter always sends the line.
  Fix: evaluate `incomplete` only when not answering a program
  (`!(surface == running && answering_)`).

## P1: Ctrl+R history

- [x] **T21 (H2). Enter is dropped while the search loads.**
  `HistoryKeys.qml:73` acts only when `!controller.loading`, which is true during the 60 ms
  debounce and the round trip. `Ctrl+L` and the hosted double click (`PromptLine.qml:1340`)
  call `use()` without the guard and show "History search is still loading" (H11).
  Expected: as fzf, Enter runs the best match for what was typed.
  Fix: if busy, Enter forces the query (stop the timer, call `query()`) and leaves a pending
  submit with its `alternate` flag, run on row 0 when that page arrives and cancelled when
  the user types or moves. Centralize the guard and the pending submit in
  `HistoryController::submit`, not in QML.

- [x] **T22 (H1). Deleting a command does not remove it: it comes back.**
  `src/runtime/history/store/store.cpp:725` deletes one run by id; with `distinct` the next
  older run with the same text takes its place.
  Expected: in the distinct view, delete removes every run of that command.
  Fix: add `all_runs` to `DeleteHistory`; the runtime runs
  `DELETE FROM command WHERE command = (SELECT command FROM command WHERE id = ?1)`; the GUI
  sets it whenever it searches with `distinct`.
  Decision: a field would change DeleteHistory's layout for older runtimes, so it is a new
  request, `DeleteHistoryCommand`, in cqp00012; the window sends it (it always searches
  distinct) and DeleteHistory to an older runtime.

- [x] **T23 (H3). After a delete the position is lost.**
  `application-history.cpp:203` refreshes offset 0; `history-browser.cpp:256` then selects
  row 0, or the last row of page 1 when coming from a later page.
  Expected: same page, selection on the next row.
  Fix: refresh at the same offset (snapshot 0) and select `min(previous selection, rows-1)`.

- [x] **T24 (H12). Two quick deletes error out.**
  `history-browser.cpp:438` throws "A history deletion is already pending"; the deleted row
  stays visible and runnable until the reply.
  Expected: deletes queue and the row disappears at once.
  Fix: remove the row locally when sending, allow several deletes in flight, and block
  actions on a row pending deletion.
  The row is gone from the page, so no action reaches it; a page that arrives drops rows still
  pending deletion. With T23: a later page its deletes emptied gives way to the one before.

- [x] **T25 (H6). The dialog pastes into whatever is in the foreground.**
  `application-history.cpp:169` checks only that the pane is alive: it concatenates with
  what the shell has typed, and with `enter_runs` sends `\r` into vim or an agent.
  Expected: it runs only when the shell is at its prompt.
  Fix: in `paste()`, send `\r` only when `shell.phase == prompt`; otherwise paste without
  running, or refuse with a message.
  Decision: paste without running. A shell without integration cannot tell its phase: there
  Enter is held back only from a full-screen program, as the window cases' plain shell needs.

- [x] **T26 (H7). Fuzzy search only sees the 10,000 newest runs.**
  `store.cpp:865-869` limits candidates before scoring and deduping; `has_more` is false.
  Expected: it finds any command.
  Fix: dedupe in SQL before the limit (`GROUP BY command` with `MAX(id)`, ordered by
  time) so the cap is 10,000 distinct commands; set `has_more` when it is reached.
  Decision: deduped while reading the started_at index instead of a `GROUP BY` over the
  whole table on every keystroke: same cap of 10,000 distinct commands, and the scan still
  stops there.

- [x] **T27 (H9). One history query cancels an unrelated one.**
  `src/runtime/workers/request_worker/request_worker.cpp:9` `supersededBy` compares only
  `distinct`; the editor's history query and the dialog's first page supersede each other.
  Expected: only a query of the same kind is replaced.
  Fix: compare scope, scope value, author, `failed_only`, `match` and `limit` too.

- [x] **T28 (H8). Case folding depends on the query length.**
  `store.cpp:953-968`: from 3 characters FTS trigram folds Unicode; below, SQLite `lower()`
  folds ASCII only ("école" finds "ÉCOLE", "éc" does not). Fuzzy compares bytes, so `é` can
  match bytes of other characters.
  Expected: the same case semantics at any length.
  Fix: register a Unicode fold SQL function and use it instead of `lower()`; fuzzy compares
  code points with the same fold.
  Decision: SQLite does not export the fold FTS5 uses, so `historyFold` (lib/base/history) is
  a simple fold of the common scripts (Latin, Greek, Cyrillic, Armenian, Georgian, fullwidth);
  a letter outside them still folds only in queries of three characters or more.

- [x] **T29 (H5). Scope matches only the exact path string.**
  `store.cpp:995-1009`: `/tmp/` and `/private/tmp`, or a trailing slash, do not match.
  Expected: the same directory matches however it was written.
  Fix: normalize on store and on query (drop trailing slash, canonicalize). Keep `cwd`
  exact: `workspace` already covers the tree.
  Rows stored before keep the path as it was written; only new rows are canonical.

- [x] **T30 (H10). The "Failed" chip sticks when the query starts with `!`.**
  `history_controller.cpp:328` shows `parsed.failed_only` and `HistoryPanel.qml:108`
  toggles from it, so it can never turn off.
  Expected: the chip shows and controls the filter.
  Fix: toggling the chip also removes the leading `!` from the search text; `\!` searches a
  literal `!`.

- [x] **T31 (H13). Closing does not stop the pending search.**
  `dialogs.cpp:61` calls `retire()`, not `forget()`; the debounce fires `query()` with the
  dialog closed, and `query()` reports to the status bar even with it open.
  Fix: in `Dialogs::show`, when the new dialog is not the history, call `history_.forget()`;
  `query()` uses `fail()`.

- [x] **T32 (H14, with H15). Detail requests fail too broadly or never retry.**
  `readOutput` never retries a failed output for the same row (`history-browser.cpp:390`);
  `track()` marks the whole page failed when the request table is full.
  Fix: allow re-reading when the output phase is `failed`; `track()` fails only the phase of
  the request that did not fit (command, output or delete).
  The full command read keeps its rule of no retry until the row is selected again, which a
  test guards against a retry loop.

- [x] **T33 (H16). Ages and "running" freeze while the dialog is open.**
  `history_controller.cpp:222` samples the clock once per rows rebuild.
  Fix: a 30 s timer while open recomputes the labels without fetching; refresh the page
  while some row is running.

- [x] **T34 (H17). Carriage returns are dropped from output.**
  `history-browser.cpp:118` `PlainText::strip` drops `\r`, so progress bars concatenate.
  Expected: the final state of each progress line shows.
  Fix: a `\r` not followed by `\n` returns to the start of the line and what follows
  overwrites it.
  What follows replaces the line from its start rather than overwriting it byte by byte, so a
  multi-byte character is never cut; progress bars redraw the whole line anyway.

- [x] **T35 (runtime extras). Two small runtime limits.**
  - `HistoryStatsEntry::command` is `Text16<65535>` but a command can be 65536 bytes: align
    the field with the command limit.
  - `workspaces()` (`store.cpp:778-801`) counts skipped empty paths against
    `LIMIT maximum_paths+1`: filter them in SQL (`WHERE path != ''`).
  Decision for the first: the wire field stays (a layout change for older peers); the
  runtime cuts the stats group to the 65,535 bytes it carries, at a character. The second
  filters every path the loop skips (empty, too long, with NUL) in SQL.

## P2: editor engine

- [x] **T36 (E22). The caret can sit inside a grapheme.**
  `prompt-layout.cpp:145-166` places the caret only at grapheme starts while `Text` moves by
  code point: with NFD `café` or a flag emoji, Left draws the caret at column 0, and
  Backspace leaves the accent alone.
  Expected: Left/Right/Backspace move by grapheme.
  Fix: `Text::previous`/`next` by grapheme with `GraphemeCursor` from `foundation/text`;
  the layout draws a caret inside a grapheme at that grapheme's column, never at 0.

- [x] **T37 (E23). Past 4096 runs the command stops rendering.**
  `Layout::maximum_runs = 4096`; `addRun` drops runs while rows keep counting.
  Expected: the whole command shows and scrolls.
  Fix: lay out only the rows visible around the caret instead of the whole text.

## P2: vim (expected: what vim does)

- [ ] **T38 (V24).** `Vjd` deletes one line: in `visualCommand` read `selectionEnd()` before
  `moveTo(start)`.
- [ ] **T39 (V25).** `dd` on the last line stores `"\nb"`: store a linewise register `b\n`;
  `p`/`P` paste whole lines for linewise registers.
- [ ] **T40 (V26).** `~`, `>>`, `<<` overwrite the unnamed register: only `d c y x s` call
  `store()`.
- [ ] **T41 (V27).** `dw` on a line's last word joins the lines: when `w` crosses into the
  next line, stop at the end of the line (vim's special case).
- [ ] **T42 (V28).** `ge`/`dge` go to a word start: add a `wordEndBackward` motion.
- [ ] **T43 (V29).** `T,` then `;` never moves: make `findBefore` symmetric with `findAfter`
  (`substr(from)`), and let `;` after `T` skip the adjacent character.
- [ ] **T44 (V30).** `d$`/`c$`/`y$` on an empty line take the newline: `lineEndMotion` is a
  no-op when `end == line`.
- [ ] **T45 (V31).** Undo grouping: one group per insert, from the operator (`c`, `o`, `s`)
  to Esc; a Backspace inside the insert does not split it (`cwxyz<Esc>u`, `oabc<Esc>u`,
  `iabc<BS>d<Esc>u`).
- [ ] **T46 (V32).** `r` followed by BS, an arrow or Delete deletes the character: cancel the
  `r` without changes.
- [ ] **T47 (V33).** Smaller ones: `3.` replaces the original count; `yy`/`Y` keep the
  cursor; `5j` with fewer lines goes to the last line; visual `l` stops at the last
  character; visual `p` honours linewise registers and stores the replaced text.
- [ ] **T48 (V34).** Visual mode is highlighted wrong: the highlighted range comes from the
  same function that computes `d`'s range; `V` marks whole lines, `v` is inclusive (the
  anchor character after `o` too).

## P2: emacs (expected: what readline does)

- [ ] **T49 (M35).** The goal column survives other motions (`Ctrl-A`, Up, `Ctrl-E`, Down
  lands at column 0): reset `goal_column_` on every action that is not Up or Down.
- [ ] **T50 (M36).** Consecutive kills do not accumulate (`Ctrl-W Ctrl-W Ctrl-Y` restores
  one word): when the previous action was a kill, prepend (backward kills) or append
  (forward kills) to the same kill ring entry.

## P3: resources

- [ ] **T51.** `put()` builds count × register before the capacity check (`9999p` with a
  256 KiB register tries ~2.5 GB): check `count * size` against the capacity first.
- [ ] **T52.** Each undo group clones the whole buffer (up to 64 MiB per pane): store diffs
  (range and previous text) instead.
- [ ] **T53.** Pasted bidi and zero-width characters (U+202E) make the shown command differ
  from the one that runs: draw them as visible marks (`⟨U+202E⟩`) in the editor.
