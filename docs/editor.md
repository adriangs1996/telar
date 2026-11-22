# Edit in a native Neovim pane

An editor pane runs Neovim on the runtime's machine and draws it in the window, without a
terminal between them. The runtime starts `nvim --embed`, is its only UI, and sends the window
what Neovim shows; the window draws it with the painter its terminals use and with its own
surfaces. On a remote machine the editor runs there, beside the files, and only what changed
on its screen crosses the connection.

![An editor pane showing a source file](images/telar-editor.png)

Open one from the palette with **New editor** or **New editor tab**, or with the prefix and
`e` or `E`. In a configuration the actions are `telar.action.new_editor()` and
`telar.action.new_editor_tab()`. The editor starts in the directory of the focused pane. The
pane's header says the file it shows and the mode it is in.

## Open a file in it

```sh
telar edit src/main.cpp:42
```

`telar edit FILE[:LINE]` shows the file in the editor pane of a tab and gives that pane the
focus. The tab is the one of the pane the command runs in; a tab without an editor pane gets
one beside it. From outside a pane, `--client ID` names the window, and without it the window
last typed in takes the request.

In a worktree, `telar worktree exec BRANCH -- telar edit FILE` opens the file in an editor
pane of a new tab of that worktree.

A file path clicked in a terminal opens the same way when the tab has an editor pane. A tab
without one opens the link as before: in the editor `editor` or `$EDITOR` names.

## What the window draws itself

Neovim leaves these to its UI, and the window draws each as one of its own surfaces:

- The command line, for `:`, a search or a prompt, with the menu that completes it.

  ![The command line with its completion menu](images/telar-editor-cmdline.png)

- The completion menu while typing. A click on an entry takes it.
- Messages, as notices that go away by themselves. An error stays longer, and none waits for
  a key.
- Tab pages, as a strip over the editor once there is more than one.

  ![Two tab pages](images/telar-editor-tabs.png)

- `vim.ui.select` and `vim.ui.input`, whatever asks and whatever the configuration loads: a
  plugin that replaces them later is ignored.

  ![A selection asked through vim.ui.select](images/telar-editor-select.png)

A floating window keeps its own cells and gets the surface and the shadow of a dialog. When
its window has a border, the window draws the frame in place of the border's characters and
writes the float's title and footer on it. A window shows how far down its buffer it is while
its text moves, and a line of the window's own stands between two windows side by side; drag
it to resize them.

![A floating window and two notices](images/telar-editor-float.png)

A scroll slides the rows to their places with the motion a terminal's rows have, and follows
the same `scroll.smooth` setting. Keys reach Neovim as what was pressed: Command and Option
are told apart from Control, and every combination with Shift arrives, which a terminal cannot
always tell Neovim.

![Two windows side by side](images/telar-editor-split.png)

## The picker

`:Telar files`, `:Telar grep` and `:Telar buffers` open a picker over the editor. The query,
the list and the keys are the window's; the runtime searches under the editor's directory and
answers with what it found, so the whole list never crosses the connection. Text is searched
with ripgrep when the machine has it, and with git in a repository when it does not.

![The picker with a file previewed](images/telar-editor-picker.png)

The palette opens the same picker on the editor of the focused tab with **Find file in
editor**, **Search text in editor** and **Switch editor buffer**; in a configuration they are
`telar.action.editor_files()`, `telar.action.editor_grep()` and `telar.action.editor_buffers()`,
to bind to a key or to call from a mod. `telar.action.edit("docs/notes.md")`, or
`telar.action.edit({ file = "src/main.cpp", line = 42 })`, opens a file by its name, taken
from the focused pane's directory.

The entry under the selection is shown beside the list in a float of Neovim itself: the
preview is the real buffer, with its highlighting. `Enter` opens the entry, `Control+Enter` or
`Command+Enter` in a split, and `Option+Enter` in a tab page. `Tab` marks entries, and `Enter` then sends the
marked ones to the quickfix list. `Shift+Tab` changes what is listed.

## telar's theme

The editor's colorscheme is the theme of the window that shows it: the same colors color the
syntax, the interface of Neovim and the surfaces above. Changing the theme in telar changes it
in the editor at once, and a `:colorscheme` set by the configuration or by a plugin is replaced
by it again. `vim.g.telar_tint` takes the options of the theme's engine, such as
`{ transparent = false }`.

![The same file after the window changed to the Vesper preset](images/telar-editor-preset.png)

## The clipboard, the focus and the directory

- The registers `+` and `*` are the clipboard of the machine you type on, wherever Neovim
  runs: what is yanked to them is copied there, unless the runtime's `clipboard_write` policy
  is `deny`. Pasting the clipboard with the window's own shortcut reaches Neovim as one change.
  `"+p` puts back the last text yanked in the editor; it does not read the clipboard.
- A link of the web or of mail opens on the machine you type on, wherever Neovim runs: `gx`,
  Command and a click, and anything a plugin opens with `vim.ui.open`. One link opens for each
  thing you do, so nothing in the editor opens links by itself. A file opens on the host, as
  `vim.ui.open` always did. Text whose highlight names a URL, as a link of a Markdown file
  does, is underlined, and the pointer over it is the one of a link.
- Moving the focus to a side with `navigate_pane` asks the editor first for a window on that
  side, and moves to the pane there when it has none. No plugin is needed for it.
- The pane's directory is the one of Neovim's current window, `:lcd` and `:tcd` included.

Nothing is installed in Neovim for any of this: the runtime teaches it when it starts, before
the configuration loads. A configuration that sets `g:clipboard` keeps its own.

## Which Neovim, and which configuration

The runtime starts, in this order: the program `TELAR_NVIM` names in the runtime's
environment; the Neovim telar provisioned; the one telar's own package ships under
`share/telar/nvim/VERSION`, beside the directory of its programs; the `nvim` on the
runtime's `PATH`. On a Linux host without glibc, where the releases of Neovim do not run,
only the first and the last are tried. It needs
Neovim 0.11 or later: an older one is refused and its pane closes.

```sh
telar integration install editor
```

fetches the Neovim release this telar was built for, checks the archive against the SHA-256
the build carries, and unpacks it under `~/.local/share/telar/nvim/VERSION`. `telar machine
setup` runs it on the machine it sets up, unless `--skip editor`. When the telar you run came
with its Neovim and the machine is of the same system and processor, setup sends it that one
first, and the machine fetches nothing. On a machine without a
network, `TELAR_NVIM_ARCHIVE=/path/to/archive` takes an archive that is already there; it is
checked the same.

Neovim reads its usual configuration. A machine without `~/.config/nvim` gets telar's own
instead: lazy.nvim with a lockfile, the language servers found on its `PATH`, git signs and
completion, with `<leader>f`, `<leader>/` and `<leader>b` on the picker. Its plugins are
fetched the first time through the pane's proxy and need git; without a network the editor
starts all the same with the parsers Neovim ships. `telar integration status editor`,
`telar machine setup` and `telar machine check` say when the host lacks git or a C compiler
for them. They are kept under the name `telar-nvim`,
so nothing of a Neovim of your own is touched, and a configuration you make later takes its
place. A runtime started with `NVIM_APPNAME` uses the configuration that names.

## Over a slow connection

In insert mode, when a key's round trip takes longer than a screen refresh, the letter is
drawn at once where it will be, underlined as a guess, until the frame that carries it
arrives. A frame that says otherwise wins. A pane whose guesses fail stops guessing, and a
local runtime answers too fast for any to be made.

## What an editor pane is not

It is a pane like any other in the layout: it splits, moves, takes the focus and closes as a
terminal does, and a session that is restored starts it again on the files it was opened with.
`telar pane read` gives the text its screen shows. What only a terminal has does not apply to
it: the prompt line, the command history, the commands' separators and searching its
scrollback. A request of that kind for an editor pane fails with `unsupported_pane_kind`.

An agent in an editor pane cannot be sent a prompt or interrupted through the pane, as one in
a terminal can. Images a plugin draws with the terminal's graphics protocol are not shown:
there is no terminal to draw them.

## Measure it

Two tools, built with the tests, measure what the runtime adds to Neovim's own time:

```sh
tools/cpp build dev -- --target nvim-redraw-bench nvim-embed-probe
out/dev/src/runtime/nvim-redraw-bench            # decoding a redraw and writing its frame
out/dev/src/runtime/nvim-embed-probe --clean     # the same against the Neovim on this host
```

`TELAR_EDITOR_METRICS=FILE` makes the window test's `editorPaneDrawsNeovim` case write how long
a key takes from the view to the frame that shows it, and `TELAR_EDITOR_SHOTS=DIR` makes it
save the window at each step. `TELAR_EDITOR_METRICS_KEYS=N` types that many keys, enough of
them to make the window scroll while it types, and `TELAR_EDITOR_METRICS_SURFACE=cmdline`
types them in the command line. Without `QT_QPA_PLATFORM=offscreen` and `QT_QUICK_BACKEND`
the case runs in a window of the desktop, drawn as the one you use is; only the measurement
is meant to pass there.

## Its reference pictures

`src/gui/tests/references/editor` keeps a picture of each surface of the editor pane, with
the Zenburn preset and with Vesper. `just gui-references` runs the same case with each preset
and fails when a surface is apart from its picture in more than 2 % of its pixels;
`just gui-references update` takes them again, and the change shows in the diff of the
pictures. They are of macOS's fonts, drawn offscreen, so the comparison is run when asked
for and not with the suite.
