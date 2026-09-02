# Telar + Neovim

This adapter lets `smart-splits.nvim` move through Neovim windows and continue
through the nearest Telar pane at an editor edge.

## Install with lazy.nvim

Frameworks such as LazyVim define their own `ctrl+h/j/k/l` mappings. Declare
the mappings in the plugin spec so lazy.nvim owns their final registration,
and disable the adapter's duplicate mappings:

```lua
local in_telar = vim.env.TELAR_PANE_ID ~= nil
  and vim.env.TELAR_PANE_ID ~= ""

return {
  dir = "/path/to/telar/integrations/nvim",
  cond = in_telar,
  dependencies = {
    "mrjones2014/smart-splits.nvim",
  },
  keys = {
    {
      "<C-h>",
      function()
        require("smart-splits").move_cursor_left()
      end,
      desc = "Move left across Neovim and Telar",
    },
    {
      "<C-j>",
      function()
        require("smart-splits").move_cursor_down()
      end,
      desc = "Move down across Neovim and Telar",
    },
    {
      "<C-k>",
      function()
        require("smart-splits").move_cursor_up()
      end,
      desc = "Move up across Neovim and Telar",
    },
    {
      "<C-l>",
      function()
        require("smart-splits").move_cursor_right()
      end,
      desc = "Move right across Neovim and Telar",
    },
  },
  config = function()
    require("telar").setup({
      keymaps = false,
    })
  end,
}
```

Without competing mappings, `require("telar").setup()` is enough. It registers
the same four normal-mode keys by default. Pass `keymaps = false` only when the
plugin spec or another config file registers them.

## Configure Telar

Telar must own the same global keys with its navigation-aware action:

```lua
config.client.keybindings = {
  telar.bind_global({ "ctrl+h" }, telar.action.navigate_pane({ direction = "left" })),
  telar.bind_global({ "ctrl+j" }, telar.action.navigate_pane({ direction = "down" })),
  telar.bind_global({ "ctrl+k" }, telar.action.navigate_pane({ direction = "up" })),
  telar.bind_global({ "ctrl+l" }, telar.action.navigate_pane({ direction = "right" })),
}
```

Do not use `focus_pane` for these keys. That action moves Telar focus before
Neovim can try one of its own windows.

Outside Neovim, Telar moves to a neighboring pane. At an outer edge it sends
the original control key to the focused process. Inside Neovim, Telar sends the
key to the editor. `smart-splits.nvim` moves within Neovim first and invokes
`telar pane focus --current` only at the editor boundary.

## Coexist with Herdr and tmux

Telar, `herdr-splits.nvim`, and `vim-tmux-navigator` all claim
`ctrl+h/j/k/l`. Their conditions must be mutually exclusive. Environment
variables from an outer multiplexer may remain set inside Telar, so a positive
`TELAR_PANE_ID` check takes precedence over `HERDR_ENV` and `TMUX`.

For `herdr-splits.nvim`:

```lua
local in_telar = vim.env.TELAR_PANE_ID ~= nil
  and vim.env.TELAR_PANE_ID ~= ""

return {
  "lmilojevicc/herdr-splits.nvim",
  cond = vim.env.HERDR_ENV == "1" and not in_telar,
}
```

For `vim-tmux-navigator`:

```lua
local in_telar = vim.env.TELAR_PANE_ID ~= nil
  and vim.env.TELAR_PANE_ID ~= ""

return {
  "christoomey/vim-tmux-navigator",
  cond = vim.env.HERDR_ENV ~= "1" and not in_telar,
}
```

`vim-tmux-navigator` installs its mappings even when `TMUX` is unset. Checking
only `HERDR_ENV` does not prevent it from overwriting the Telar mappings.

## Troubleshooting

### Confirm the active mapping

Run this inside the failing Neovim instance:

```vim
:verbose nmap <C-k>
```

Replace `<C-k>` with the failing direction. The mapping should describe moving
across Neovim and Telar. The output also names the file that last set it.

| Active mapping | Cause |
| --- | --- |
| `<C-w>k`, `Go to Upper Window` | A Neovim distribution overwrote the mapping |
| `TmuxNavigateUp` | `vim-tmux-navigator` loaded inside Telar |
| A `herdr-splits` callback | Herdr remained enabled inside Telar |
| `Move up across Neovim and Telar` | The expected mapping is active |

Do this check in the actual Telar pane. A separate `nvim --headless` process
does not inherit that pane's environment and can produce a false diagnosis.

### Confirm the backend and pane identity

```vim
:lua print(require("smart-splits.config").multiplexer_integration)
:lua print(vim.env.TELAR_PANE_ID, vim.env.TELAR_PANE_GENERATION, vim.env.TELAR_BIN_PATH)
```

The first command must print `telar`. The other values must all be non-empty.
`TELAR_BIN_PATH` lets development builds call the exact Telar binary that
created the pane instead of whichever `telar` happens to be on `PATH`.

### Run the bridge directly

This command may move the current Telar focus. Replace `up` with the direction
that has a visible neighboring pane:

```vim
:lua vim.print(vim.system({ vim.env.TELAR_BIN_PATH, "pane", "focus", "--current", "--direction", "up", "--json" }, { text = true }):wait())
```

A successful response has exit code zero and one of these reasons:

- `focused`: Telar moved to the neighboring pane.
- `no_neighbor`: the client layout has no pane in that direction. This is not
  a transport failure. Check the actual layout direction.
- `source_not_focused`: the Neovim pane was no longer focused when the client
  handled the request.

If the direct command works but the key does not, inspect the active mapping.
If the key reaches Neovim but selection fails, inspect the smart-splits log.

### Inspect logs

Open the smart-splits log and enable debug messages with:

```vim
:SmartSplitsLog
:SmartSplitsLogLevel debug
```

The file lives at:

```vim
:lua print(vim.fn.stdpath("log") .. "/smart_splits_nvim/log.txt")
```

Debug Telar builds write runtime and client JSON Lines logs beside
`TELAR_SOCKET_PATH`:

```sh
ls "${TELAR_SOCKET_PATH}".*.log
```

These Telar logs contain counters and queue state. They deliberately exclude
PTY contents and do not record every CLI response. Use the direct bridge command
to capture `stdout`, `stderr`, and the exit code for one navigation attempt.

### Restart the right process

- After changing Neovim plugins or mappings, restart Neovim. The Telar runtime
  can stay running.
- After rebuilding changes to Telar's protocol or runtime navigation code,
  restart both the runtime and client.
- After changing only the adapter's Lua files, restart Neovim.

## Test the adapter

```sh
TELAR_NVIM_INTEGRATION="$PWD/integrations/nvim" nvim --headless -u NONE \
  -l integrations/nvim/tests/telar_mux_spec.lua
```
