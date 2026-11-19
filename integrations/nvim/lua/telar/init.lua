-- Neovim inside a telar pane: the window's theme as the colorscheme, and ctrl+h/j/k/l moving
-- across Neovim's windows and telar's panes. `telar integration install neovim` installs it,
-- and plugin/telar.lua starts it in a pane with the options the `vim.g.telar_*` variables give.
local M = {}

-- The telar the pane runs under, which the runtime names in TELAR_BIN_PATH.
function M.bin()
  local path = vim.env.TELAR_BIN_PATH
  return path ~= nil and path ~= "" and path or "telar"
end

function M.in_pane()
  local pane = vim.env.TELAR_PANE_ID
  return pane ~= nil and pane ~= ""
end

local started = false

-- Options, each also read from `vim.g.telar_<name>`:
--   colorscheme  false keeps your colorscheme instead of the window's theme.
--   keymaps      false maps nothing; a table maps other keys ({ left = "<M-h>", ... }).
--   tint         options for the colorscheme's engine, such as { transparent = false }.
function M.setup(options)
  if started or not M.in_pane() then
    return
  end

  started = true
  options = vim.tbl_extend("force", {
    colorscheme = vim.g.telar_colorscheme,
    keymaps = vim.g.telar_keymaps,
    tint = vim.g.telar_tint,
  }, options or {})

  if options.colorscheme ~= false then
    require("telar.theme").follow(options.tint)
  end

  if options.keymaps ~= false then
    local keys = type(options.keymaps) == "table" and options.keymaps or nil
    local function map()
      require("telar.navigate").map(keys)
    end

    -- Distributions such as LazyVim map these keys once Neovim has started; mapping again then
    -- keeps telar's.
    local group = vim.api.nvim_create_augroup("TelarKeymaps", { clear = true })
    if vim.v.vim_did_enter == 1 then
      map()
    else
      vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = map })
    end

    vim.api.nvim_create_autocmd("User", { group = group, pattern = "VeryLazy", once = true, callback = map })
  end
end

return M
