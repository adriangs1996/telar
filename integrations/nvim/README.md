# Telar + Neovim

Inside a Telar pane, this plugin:

- paints Neovim with the theme of the Telar window showing the pane, including the
  syntax and interface colors that the 16 ANSI colors cannot hold, on whatever
  machine the pane runs;
- maps `ctrl+h/j/k/l` to move through Neovim windows and, at the editor's edge, to
  the neighboring Telar pane.

Outside a Telar pane (no `TELAR_PANE_ID`) it does nothing.

## Install

```sh
telar integration install neovim
```

This writes the plugin under Neovim's site directory,
`$XDG_DATA_HOME/$NVIM_APPNAME/site` (by default `~/.local/share/nvim/site`).
Neovim loads it from there without any configuration, and so does lazy.nvim, which
keeps that directory on the runtime path. Run the command again after upgrading
Telar so the plugin matches the CLI it calls. On a remote machine, run it there:
the plugin runs where Neovim runs.

```sh
telar integration status neovim     # one line per file: installed, absent or foreign
telar integration uninstall neovim  # removes only the files Telar wrote
```

Every file starts with `-- telar-integration: neovim`. A file at one of the plugin's
paths without that line stops the install before anything is written.

## The theme

The Telar window gives the runtime its theme when it connects and whenever the
theme changes. `telar pane theme --current` prints it as JSON:

- the terminal's foreground, background, cursor and 16 ANSI colors;
- the color, italic and bold of each syntax role;
- the interface (chrome) colors.

The plugin turns that into the `telar` colorscheme through the tint engine.

It follows the window's theme while Neovim runs. When the terminal colors change,
Telar announces it (DEC mode 2031), Neovim asks the terminal for its background
again, and the plugin reads the whole theme. A theme change that leaves the
terminal colors untouched is picked up the next time Neovim starts, or with
`:lua require("telar.theme").refresh()`.

By default Neovim draws no background of its own, so the window's background and
its opacity show through. To paint it anyway:

```lua
vim.g.telar_tint = { transparent = false }
```

After every repaint the plugin fires `User TelarTheme`, so the rest of your
configuration can refresh with the theme:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "TelarTheme",
  callback = function()
    require("lualine").setup({ options = { theme = "telar" } })
  end,
})
```

`lualine` gets the theme as `theme = "telar"`. tint also builds bufferline
highlights: `require("telar.tint").bufferline_highlights("telar")`.

To keep your own colorscheme:

```lua
vim.g.telar_colorscheme = false
```

## Moving across Neovim and Telar

`ctrl+h/j/k/l` move the cursor one Neovim window left, down, up or right. At the
editor's edge they run `telar pane focus --current --direction D` instead. The plugin
maps them once Neovim has started, and again after lazy.nvim's `VeryLazy`, so that
distributions such as LazyVim, which map the same keys, do not overwrite them.

Other keys, or none:

```lua
vim.g.telar_keymaps = { left = "<M-h>", down = "<M-j>", up = "<M-k>", right = "<M-l>" }
vim.g.telar_keymaps = false
```

Set these variables before the plugin loads, for example at the top of `init.lua`.
You can also call `require("telar").setup({ colorscheme = ..., keymaps = ..., tint = ... })`
yourself before Neovim sources its plugins.

### Configure Telar

Telar must own the same global keys with its navigation-aware action. This is a
complete Telar `config.lua`. If you already have one, merge the bindings into
`client.keybindings` and keep a single return statement. See the
[configuration guide](../../docs/configuration.md#start-with-a-small-config) for the
file location and validation.

```lua
local telar = require("telar")

return telar.config({
  api_version = 2,
  client = {
    keybindings = {
      telar.bind_global({ "ctrl+h" }, telar.action.navigate_pane({ direction = "left" })),
      telar.bind_global({ "ctrl+j" }, telar.action.navigate_pane({ direction = "down" })),
      telar.bind_global({ "ctrl+k" }, telar.action.navigate_pane({ direction = "up" })),
      telar.bind_global({ "ctrl+l" }, telar.action.navigate_pane({ direction = "right" })),
    },
  },
})
```

Do not use `focus_pane` for these keys. That action moves Telar's focus before
Neovim can try one of its own windows.

Outside Neovim, Telar moves to a neighboring pane, and at an outer edge it sends the
original control key to the focused process. Inside Neovim, Telar sends the key to
the editor.

### Coexist with Herdr and tmux

`herdr-splits.nvim` and `vim-tmux-navigator` also claim `ctrl+h/j/k/l`. Variables of
an outer multiplexer may remain set inside Telar, so disable those plugins whenever
`TELAR_PANE_ID` is set:

```lua
local in_telar = vim.env.TELAR_PANE_ID ~= nil and vim.env.TELAR_PANE_ID ~= ""

return {
  "christoomey/vim-tmux-navigator",
  cond = not in_telar,
}
```

`vim-tmux-navigator` installs its mappings even when `TMUX` is unset.

## Troubleshooting

Check inside the Telar pane itself: a separate `nvim --headless` does not inherit
the pane's environment.

```vim
:lua print(vim.env.TELAR_PANE_ID, vim.env.TELAR_PANE_GENERATION, vim.env.TELAR_BIN_PATH)
:lua vim.print(vim.system({ vim.env.TELAR_BIN_PATH, "pane", "theme", "--current" }, { text = true }):wait())
:verbose nmap <C-k>
```

- All three variables must be non-empty. `TELAR_BIN_PATH` makes the plugin call the
  Telar that created the pane, not whichever `telar` is first on `PATH`.
- `NoTheme` from `pane theme` means no Telar window owns the pane's workspace, or the
  window is older than this plugin.
- The mapping must read `Move up across Neovim and telar`. Any other line names the
  file that overwrote it.

`telar pane focus --current --direction D --json` answers `focused`; `no_neighbor`
when the layout has no pane that way; or `source_not_focused` when the Neovim pane
lost focus before the window handled the request.
