-- telar's own Neovim configuration, the base every editor pane starts on: the runtime names it
-- with `-u`, so the configuration of the user's own Neovim is never read. It installs nothing
-- and fetches nothing: no plugins and no language servers. Text is highlighted by the parsers
-- Neovim ships and the ones telar brings, and, for the other languages, by Neovim's syntax files.
--
-- The user's layer goes over it: ~/.config/telar/editor/init.lua, the directory Neovim runs
-- under (NVIM_APPNAME=telar/editor), so its lua/ and plugin/ load as a configuration's do.
-- What it installs, with vim.pack or lazy.nvim, is its own; its lockfile stays beside it.

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local options = {
  number = true,
  relativenumber = false,
  signcolumn = "yes",
  cursorline = true,
  termguicolors = true,
  undofile = true,
  ignorecase = true,
  smartcase = true,
  splitright = true,
  splitbelow = true,
  expandtab = true,
  shiftwidth = 2,
  tabstop = 2,
  scrolloff = 4,
  updatetime = 250,
  timeoutlen = 400,
  wrap = false,
  showmode = false,
  laststatus = 3,
  completeopt = "menu,menuone,noselect",
}

for name, value in pairs(options) do
  vim.o[name] = value
end

-- The status line opens with the mode, where an editor's users look for it: the window writes
-- it in the theme's color for the mode. The rest is the line Neovim has by default, and a line
-- the user's layer sets takes the place of both.
local modes = {
  n = "NORMAL",
  i = "INSERT",
  v = "VISUAL",
  V = "V-LINE",
  ["\22"] = "V-BLOCK",
  s = "SELECT",
  S = "S-LINE",
  ["\19"] = "S-BLOCK",
  R = "REPLACE",
  c = "COMMAND",
  t = "TERMINAL",
}

function _G.TelarMode()
  local mode = vim.fn.mode(1)
  if mode:sub(1, 2) == "no" then
    return "O-PENDING"
  end

  return modes[mode:sub(1, 1)] or ""
end

-- Before 0.12 the default line is Neovim's own code, not an option's text.
local line = vim.o.statusline ~= "" and vim.o.statusline or "%<%f %h%w%m%r %=%-14.(%l,%c%V%) %P"
vim.o.statusline = " %{v:lua.TelarMode()}  " .. line

-- Neovim draws the line again for some changes of mode and not for others, as an operator
-- that waits for its motion.
vim.api.nvim_create_autocmd("ModeChanged", {
  group = vim.api.nvim_create_augroup("TelarMode", { clear = true }),
  command = "redrawstatus",
})

-- The window draws the completion menu: "match 1 of 3" would only come as one more notice.
vim.opt.shortmess:append("c")

-- The window's picker, which the runtime searches for: files, text and buffers.
vim.keymap.set("n", "<leader>f", "<Cmd>Telar files<CR>", { desc = "Find files" })
vim.keymap.set("n", "<leader>/", "<Cmd>Telar grep<CR>", { desc = "Search text" })
vim.keymap.set("n", "<leader>b", "<Cmd>Telar buffers<CR>", { desc = "Buffers" })
vim.keymap.set("n", "<Esc>", "<Cmd>nohlsearch<CR>")

-- The parsers and queries telar brings for the languages Neovim ships none of, after everything
-- else on the runtimepath: a parser the user's layer installs takes their place.
if vim.env.TELAR_EDITOR_RUNTIME and vim.env.TELAR_EDITOR_RUNTIME ~= "" then
  vim.opt.rtp:append(vim.env.TELAR_EDITOR_RUNTIME)
end

-- A language with a parser is highlighted by it; any other keeps its syntax file.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("TelarTreesitter", { clear = true }),
  callback = function(event)
    pcall(vim.treesitter.start, event.buf)
  end,
})

-- The user's layer, last: what it sets wins. One that fails leaves the base working and says why.
local user = vim.fn.stdpath("config") .. "/init.lua"
if vim.uv.fs_stat(user) then
  vim.env.MYVIMRC = user
  local ok, failure = pcall(dofile, user)
  if not ok then
    vim.schedule(function()
      vim.notify("telar: " .. user .. " failed: " .. tostring(failure), vim.log.levels.ERROR)
    end)
  end
end
