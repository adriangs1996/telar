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

-- Indent guides: a line at each level of a line's indentation, and across the blank lines of a
-- block. They are marks for one redraw, made only for the lines Neovim draws. A blank line takes
-- the shallower indentation of the lines around it, one level deeper when those differ. A line
-- aligned past its block, as an argument under its parenthesis, gets one guide more than the
-- line above it, not one for each column. A layer that draws its own sets
-- vim.g.telar_indent_guides = false.
local guides = vim.api.nvim_create_namespace("TelarIndentGuides")

-- By window: the indentation of its buffer's lines, kept until the buffer changes.
local measured = {}

-- By indentation, shiftwidth, first column shown and whether a wrapped line repeats them.
local guide_marks = {}

local function marks_for(indent, step, left, repeated)
  local key = indent .. ":" .. step .. ":" .. left .. (repeated and ":r" or "")
  local marks = guide_marks[key]
  if marks then
    return marks
  end

  marks = {}
  for level = 1, math.floor(indent / step) do
    local column = (level - 1) * step - left
    if column >= 0 then
      marks[#marks + 1] = {
        virt_text = { { "│", "Whitespace" } },
        virt_text_pos = "overlay",
        virt_text_win_col = column,
        virt_text_repeat_linebreak = repeated or nil,
        hl_mode = "combine",
        priority = 1,
        ephemeral = true,
      }
    end
  end

  guide_marks[key] = marks
  return marks
end

local function draw_guides(window, buffer, top, bottom)
  local tick = vim.b[buffer].changedtick
  local known = measured[window]
  if not known or known.buffer ~= buffer or known.tick ~= tick then
    known = { buffer = buffer, tick = tick, indents = { [0] = 0 } }
    measured[window] = known
  end

  local indents = known.indents
  local function indent_of(line)
    local indent = indents[line]
    if not indent then
      indent = vim.fn.indent(line)
      indents[line] = indent
    end

    return indent
  end

  local step = vim.fn.shiftwidth()
  local left = vim.fn.winsaveview().leftcol
  -- Without breakindent the rest of a wrapped line starts at its first column, under a guide.
  local repeated = vim.wo[window].wrap and vim.wo[window].breakindent
  local parent, current

  for line = top, math.min(bottom, vim.api.nvim_buf_line_count(buffer)) do
    local indent = indents[line]
    if not indent then
      local following = vim.fn.nextnonblank(line)
      if following == line then
        indent = indent_of(line)
      else
        local before, after = indent_of(vim.fn.prevnonblank(line)), indent_of(following)
        indent = math.min(before, after)
        if before ~= after and indent > 0 then
          indent = indent + step
        end

        indents[line] = indent
      end
    end

    if indent ~= current then
      parent = current or indent
      current = indent
    end

    indent = math.min(indent, parent + step)
    if indent >= step then
      for _, mark in ipairs(marks_for(indent, step, left, repeated)) do
        vim.api.nvim_buf_set_extmark(buffer, guides, line - 1, 0, mark)
      end
    end
  end
end

vim.api.nvim_set_decoration_provider(guides, {
  on_win = function(_, window, buffer, top, bottom)
    if vim.g.telar_indent_guides == false or vim.bo[buffer].buftype ~= "" then
      return false
    end

    vim.api.nvim_win_call(window, function()
      draw_guides(window, buffer, top + 1, bottom + 1)
    end)

    return false
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("TelarIndentGuides", { clear = true }),
  callback = function(event)
    measured[tonumber(event.match)] = nil
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
