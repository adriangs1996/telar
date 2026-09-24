# Reusing terminal editors for agent file links

A completed click on an agent message's local file link enters
`editor_file_links.openMessageFile`. The client looks for the configured editor in
that source tab. If there is a candidate, `open_editor` asks the runtime to open
the file in an existing instance. `editor_opened` reports the exact pane and
runtime generation; `editor_file_links.completeEditorOpen` focuses that pane
through the existing pane focus path.

The runtime's `link_opening.start` admits the request: it checks the source
generation and collects live terminal panes in the same tab.
`editors/Job.zig` runs an `editorremote.Search` on an observation worker,
which discovers servers and opens the file, and maps the accepting candidate
back to its pane; `link_opening.finish` delivers the reply. It never writes commands or simulated keys to a
PTY. Names only select candidates; the remote editor's process identity, and
for Emacs the frame's terminal device, identify the destination.

## Supported connections

- Neovim: local default sockets below `XDG_RUNTIME_DIR` or
  `${TMPDIR:-/tmp}/nvim.$USER`. Discovery visits the root and one directory
  level below it. The remote PID must match a candidate's foreground process
  group. Custom sockets outside these locations are not discovered.
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
  connection: the existing split flow launches the configured executable with
  the file as its own argv entry.

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
real Neovim identity and file opening when Neovim is installed, runtime tab
selection, admission bounds and stale sources. When the GUI adapter is enabled,
it also runs the relevant GUI tests. `zig build test-gui` runs the full GUI suite,
which exercises
actual message-link clicks through `model.to_runtime` and reply dispatch,
including fallback, duplicate replies, Nano and replaced pane identities.
