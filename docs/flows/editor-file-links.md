# Reusing terminal editors for file links

`editor_file_links.openFile(client, pane_id, path)` opens a local file linked
from a pane, at the line the link names. `link_opening.openLink` calls it for
every `file://` link and every path found in prose (see
[link opening](link-opening.md#file-paths-in-prose)); the GUI, the TUI, copy
mode and `telar client open-link` pass the pane the link came from.

The client anchors the path first, without touching the filesystem: an absolute
path stays literal, `~` resolves against the client's HOME and a relative path
against the source pane's directory, and `.` and `..` collapse. The pane's
directory is the runtime's, so a relative path is right over `telar remote` too;
`~` is not, and a remote runtime whose home differs answers `missing`. The request
carries the absolute path, the line and the column; zero means the link named
none. `open_editor` always goes to the runtime once the source pane has a
runtime generation. `editor_opened` reports the exact pane and runtime
generation; `editor_file_links.completeEditorOpen` focuses that pane through
the existing pane focus path, splits a new editor on `unavailable`, and reports
`missing` as a warning without opening anything.

The runtime's `link_opening.start` admits the request: it checks the source
generation and collects live terminal panes in the same tab.
`editors/Job.zig` runs on an observation worker: it first requires a regular
file at the path, then runs an `editorremote.Search`, which discovers servers,
opens the file, moves the cursor, and maps the accepting candidate back to its
pane; `link_opening.finish` delivers the reply. It never writes commands or
simulated keys to a PTY. Names only select candidates; the remote editor's
process identity, and for Emacs the frame's terminal device, identify the
destination.

## Lines

A reused editor moves the cursor inside the same remote evaluation that opens
the file: Vim and Neovim call `cursor(line, column)` after `drop`, Emacs runs
`goto-char`, `forward-line` and `move-to-column` after `find-file`. Only
integers join those expressions.

A new editor gets the line on its command line through `editorremote.Launch`:

| Editor | Arguments |
| --- | --- |
| `nvim`, `vim`, `vi` | `+12 path`, or `+call cursor(12, 3) path` with a column |
| `emacs`, `emacsclient`, `kak`, `micro` | `+12:3 path` |
| `nano` | `+12,3 path` |
| `hx`, `helix` | `path:12:3` |
| `code`, `code-insiders`, `codium`, `cursor` | `-g path:12:3` |
| anything else | `path`, without a position |

The path is always absolute, so it can never read as an option.

## Supported connections

- Neovim: local default sockets below `XDG_RUNTIME_DIR` or
  `${TMPDIR:-/tmp}/nvim.$USER`. Discovery visits the root and one directory
  level below it. The remote PID, or its parent's, must match a candidate's
  foreground process group: Neovim 0.10 and later run the TUI in the pane and
  the server that owns the socket as its child. Custom sockets outside these
  locations are not discovered.
- Vim and `vi`: servers advertised by `--serverlist`. The installation must
  support client-server commands and the editor must have a running server.
  PID and hostname must match the runtime's local candidate.
- Emacs and `emacsclient`: Unix sockets below `XDG_RUNTIME_DIR/emacs` or
  `${TMPDIR:-/tmp}/emacs<uid>`, plus an absolute `EMACS_SOCKET_NAME` from the
  runtime environment. `server-start` or an Emacs daemon must already be
  active. The worker gets each candidate's TTY using `ps` and selects the
  local server frame attached to that device, checking PID and hostname again
  in the opening command. Other frames are left alone.
- Nano, unrecognized executable wrappers and editors without a discoverable
  connection: the runtime replies `unavailable` once the file exists, and the
  split flow launches the configured executable with the file as its own argv
  entry and the line as the editor reads it.

Opening a new pane does not enable an editor server or change editor settings.
Vim/Neovim filenames are quoted as Vim strings and passed through `fnameescape`.
Emacs filenames are quoted as Lisp strings and prefixed with `/:` to disable
filename handlers such as TRAMP. Neither path passes through a shell. Files
with unsaved changes are not forcibly saved or discarded.

## Bounds and recovery

The client retains one open request, including its original editor setting and
source attachment generation. The runtime reserves one worker globally, with
at most `max_panes_per_tab` candidates, 128 directory entries, 32 socket/server
candidates and 128 helper invocations. Helpers share a three-second deadline,
with 16 KiB stdout and stderr limits. Local discovery rejects symlinks,
wrong-owner endpoints and group/world-writable directories or sockets.

The wire request borrows bounded strings; only `model.to_runtime`, client continuation
state and worker retain copies. Ordinary input messages do not inherit the
storage size of file paths. Discovery and subprocess work never run in the
runtime's input or PTY loop. There is no editor polling while idle.

An unavailable connection triggers `create_pane` using the original executable
and path. A failed or timed-out remote open reports an error instead: the file
might already have opened, so creating another pane would duplicate the action.
A busy worker rejects admission explicitly. Duplicate replies are consumed only
once. Replaced or detached sources cannot trigger a late split or focus change.
Replies for disconnected client generations are discarded. Runtime shutdown
joins the worker before releasing its storage; closing a client does not destroy
the editor process.

## Verification

`zig build test-editors` checks the wire corpus, path validation and quoting,
real Neovim identity, file opening and cursor placement when Neovim is
installed, a server whose parent is the pane's process, missing files in the
runtime worker, runtime tab selection, admission bounds and stale sources. When the GUI adapter is enabled,
it also runs the relevant GUI tests. `zig build test-gui` calls `openFile`
directly and follows the request through `model.to_runtime` and reply dispatch,
including fallback, duplicate replies, Nano and replaced pane identities.
