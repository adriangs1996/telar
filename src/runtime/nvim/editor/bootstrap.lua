-- What the runtime runs in a Neovim it embeds, before Neovim reads the user's configuration.
-- It is telar's side of the conversation inside Neovim: every `telar_*` notification the
-- runtime accepts is sent from here, and every `__telar_*` function is one the runtime calls.
local channel, modules = ...

-- telar's own modules, as this runtime has them: nothing is installed on the host.
for name, source in pairs(modules) do
  package.preload[name] = function()
    return assert(loadstring(source, "=" .. name))()
  end
end

-- vim.ui.select and vim.ui.input ask the runtime, which shows them natively, and nothing loaded
-- later can put its own in their place, nor in the place of vim.ui.open below. The answer comes
-- back through __telar_prompt_answer.
local pending, last = {}, 0
local function ask(kind, title, initial, choices, done, origin)
  last = last + 1
  pending[last] = done
  vim.rpcnotify(channel, "telar_prompt", last, kind, tostring(title or ""), tostring(initial or ""), choices, tostring(origin or ""))
end

-- Who asks, as the selector shows it beside its title: the language server whose code actions
-- these are, or the kind the caller gives.
local function origin(items, opts)
  local first = type(items[1]) == "table" and items[1] or {}
  local context = type(first.ctx) == "table" and first.ctx or {}
  if opts.kind == "codeaction" and context.client_id then
    local client = vim.lsp.get_client_by_id(context.client_id)
    if client then
      return client.name
    end
  end

  return type(opts.kind) == "string" and opts.kind or ""
end

local function select(items, opts, on_choice)
  opts = opts or {}
  local format = opts.format_item or tostring
  local choices = {}
  for index, item in ipairs(items) do
    choices[index] = tostring(format(item))
  end

  ask("select", opts.prompt, "", choices, function(accepted, index)
    if accepted and items[index] ~= nil then
      on_choice(items[index], index)
    else
      on_choice(nil, nil)
    end
  end, origin(items, opts))
end

local function input(opts, on_confirm)
  opts = opts or {}
  ask("input", opts.prompt, opts.default, {}, function(accepted, _, text)
    on_confirm(accepted and text or nil)
  end)
end

function _G.__telar_prompt_answer(id, accepted, index, text)
  local done = pending[id]
  pending[id] = nil
  if done then
    vim.schedule(function()
      done(accepted, index, text)
    end)
  end
end

local ui = vim.ui

-- A link of the web or of mail opens where the person is, which is not always where this
-- Neovim runs: `gx` and anything else that calls vim.ui.open reach the runtime. A file is of
-- this host, and opens here as it always did.
local function open(target, ...)
  if type(target) == "string" and (target:match("^https?://") or target:match("^mailto:")) then
    vim.rpcnotify(channel, "telar_open", target)
    return nil, nil
  end

  return ui.open(target, ...)
end

local own = { select = select, input = input, open = open }
local guarded = setmetatable({}, {
  __index = function(_, key)
    return own[key] or ui[key]
  end,
  __newindex = function(_, key, value)
    if own[key] == nil then
      ui[key] = value
    end
  end,
})
package.loaded["vim.ui"] = guarded
vim.ui = guarded

local group = vim.api.nvim_create_augroup("TelarEmbed", { clear = true })

-- The window's theme is the colorscheme. A colorscheme the configuration or a plugin sets
-- afterwards is replaced by it again.
local theme, applying = nil, false
local function paint()
  if theme == nil or applying then
    return
  end

  applying = true
  pcall(function()
    require("telar.theme").apply(theme, vim.g.telar_tint)
  end)
  applying = false
end

function _G.__telar_theme(colors)
  theme = colors
  paint()
end

vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = paint })

-- The registers + and * are the clipboard of whoever is typing, wherever this Neovim runs. What
-- is yanked goes to the runtime; what is put is the last text yanked here, and a paste of the
-- window's own clipboard arrives as nvim_paste.
if vim.g.clipboard == nil then
  local kept = { {}, "v" }
  local function copy(lines, regtype)
    kept = { lines, regtype }
    vim.rpcnotify(channel, "telar_clipboard", table.concat(lines, "\n"))
  end

  local function paste()
    return kept
  end

  vim.g.clipboard = {
    name = "telar",
    copy = { ["+"] = copy, ["*"] = copy },
    paste = { ["+"] = paste, ["*"] = paste },
    cache_enabled = 0,
  }
end

-- The directory of the current window, which `:lcd` and `:tcd` change without telling the UI.
local directory = nil
local function report()
  local current = vim.fn.getcwd()
  if current ~= directory then
    directory = current
    vim.rpcnotify(channel, "telar_directory", current)
  end
end

vim.api.nvim_create_autocmd({ "DirChanged", "WinEnter", "TabEnter", "VimEnter" }, { group = group, callback = report })

-- Command and a click follows the link under the pointer, as it does in a terminal of telar.
vim.keymap.set("n", "<D-LeftMouse>", "<LeftMouse>gx", { remap = true, silent = true, desc = "Open the link under the pointer" })

-- What Neovim's own tab line does not say of a tab page: whether the buffer of its window in
-- use has changes not written, and how many warnings and errors its diagnostics have.
local marked = nil
local function tell_tabs()
  local tabs, key = {}, {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local found, window = pcall(vim.api.nvim_tabpage_get_win, tab)
    if found then
      local buffer = vim.api.nvim_win_get_buf(window)
      local modified = vim.bo[buffer].modified
      local diagnostics = #vim.diagnostic.get(buffer, { severity = { min = vim.diagnostic.severity.WARN } })
      if modified or diagnostics > 0 then
        tabs[#tabs + 1] = { tab, modified, diagnostics }
        key[#key + 1] = tab .. (modified and "+" or "-") .. diagnostics
      end
    end
  end

  local now = table.concat(key, ",")
  if now ~= marked then
    marked = now
    vim.rpcnotify(channel, "telar_tabs", tabs)
  end
end

vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufEnter", "BufWritePost", "WinEnter", "TabEnter", "TabClosed", "DiagnosticChanged" }, {
  group = group,
  callback = function()
    vim.schedule(tell_tabs)
  end,
})

-- The row of the status line of the whole editor, which the window draws natively: the one
-- above the command line while 'laststatus' is 3, and none otherwise.
local status_row = nil
local function tell_status()
  local row = vim.o.laststatus == 3 and vim.o.lines - vim.o.cmdheight - 1 or -1
  if row ~= status_row then
    status_row = row
    vim.rpcnotify(channel, "telar_status", row)
  end
end

-- A status line that comes or goes resizes the windows, whoever set the option and when.
vim.api.nvim_create_autocmd({ "VimEnter", "UIEnter", "VimResized", "WinResized" }, { group = group, callback = tell_status })
vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = { "laststatus", "cmdheight" }, callback = tell_status })

-- The pane's header shows the file being edited, unless the configuration names something else.
vim.o.title = true
vim.o.titlestring = "%t%( %M%)"

-- Moves to the window on a side. Without one there, the runtime is told, and the pane on that
-- side takes the focus.
local sides = { left = "h", down = "j", up = "k", right = "l" }
function _G.__telar_navigate(direction)
  local key = sides[direction]
  if key == nil then
    return
  end

  local before = vim.api.nvim_get_current_win()
  vim.cmd("wincmd " .. key)
  if vim.api.nvim_get_current_win() == before then
    vim.rpcnotify(channel, "telar_navigate", direction)
  end
end

-- What a float's own configuration says of its frame: the sides Neovim draws a border on, as
-- top 1, right 2, bottom 4 and left 8, its title and its footer. The window draws them itself.
local function flat(value)
  if type(value) == "string" then
    return value
  end

  local parts = {}
  for _, chunk in ipairs(type(value) == "table" and value or {}) do
    parts[#parts + 1] = tostring(type(chunk) == "table" and chunk[1] or chunk)
  end

  return table.concat(parts)
end

local function bordered(border)
  if type(border) == "string" then
    if border == "" or border == "none" then
      return 0
    end

    return border == "shadow" and 6 or 15
  end

  if type(border) ~= "table" or #border == 0 then
    return 0
  end

  -- Eight characters from the top left corner, clockwise; a shorter list repeats.
  local function drawn(index)
    local part = border[((index - 1) % #border) + 1]
    if type(part) == "table" then
      part = part[1]
    end

    return part ~= nil and part ~= ""
  end

  return (drawn(2) and 1 or 0) + (drawn(4) and 2 or 0) + (drawn(6) and 4 or 0) + (drawn(8) and 8 or 0)
end

function _G.__telar_float(window)
  local found, config = pcall(vim.api.nvim_win_get_config, window)
  if found and config.relative ~= "" then
    vim.rpcnotify(channel, "telar_float", window, bordered(config.border), flat(config.title), flat(config.footer))
  end
end

-- `:Telar files`, `:Telar grep` and `:Telar buffers` ask the window for its picker.
local sources = { "files", "grep", "buffers" }
vim.api.nvim_create_user_command("Telar", function(command)
  if vim.tbl_contains(sources, command.args) then
    vim.rpcnotify(channel, "telar_pick", command.args)
  else
    vim.notify("Telar: files, grep or buffers", vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  complete = function()
    return sources
  end,
})

-- The listed buffers that have a name, most recently used first.
function _G.__telar_buffers(token)
  local buffers = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(buffers, function(one, other)
    return one.lastused > other.lastused
  end)

  local names = {}
  for _, buffer in ipairs(buffers) do
    if buffer.name ~= "" then
      names[#names + 1] = vim.fn.fnamemodify(buffer.name, ":~:.")
    end
  end

  vim.rpcnotify(channel, "telar_buffers", token, names)
end

-- A file shown in a float that takes no focus, over the cells a picker leaves for it. The
-- buffers it loads only to show are dropped when it closes.
local preview, loaded = nil, {}
local function close_preview()
  if preview ~= nil and vim.api.nvim_win_is_valid(preview) then
    vim.api.nvim_win_close(preview, true)
  end

  preview = nil
  for buffer in pairs(loaded) do
    if vim.api.nvim_buf_is_valid(buffer) and not vim.bo[buffer].buflisted and #vim.fn.win_findbuf(buffer) == 0 then
      pcall(vim.api.nvim_buf_delete, buffer, {})
    end
  end

  loaded = {}
end

function _G.__telar_preview(path, line, row, column, columns, rows)
  if columns == 0 or rows == 0 or path == "" then
    close_preview()
    return
  end

  local known = vim.fn.bufexists(path) == 1
  local buffer = vim.fn.bufadd(path)
  if not known then
    loaded[buffer] = true
  end

  if not pcall(vim.fn.bufload, buffer) then
    return
  end

  local config = { relative = "editor", row = row, col = column, width = columns, height = rows, focusable = false, style = "minimal", zindex = 250 }
  if preview ~= nil and vim.api.nvim_win_is_valid(preview) then
    vim.api.nvim_win_set_buf(preview, buffer)
    vim.api.nvim_win_set_config(preview, config)
  else
    config.noautocmd = true
    preview = vim.api.nvim_open_win(buffer, false, config)
  end

  vim.wo[preview].number = true
  vim.wo[preview].wrap = false
  vim.wo[preview].cursorline = line > 0
  if line > 0 then
    pcall(vim.api.nvim_win_set_cursor, preview, { line, 0 })
    vim.api.nvim_win_call(preview, function()
      vim.cmd("normal! zz")
    end)
  end
end

-- Places as `{path, line, column, text}`, into the quickfix list.
function _G.__telar_list(places)
  local items = {}
  for index, place in ipairs(places) do
    items[index] = { filename = place[1], lnum = place[2], col = place[3], text = place[4] }
  end

  vim.fn.setqflist({}, " ", { title = "telar", items = items })
  vim.cmd("botright copen")
end
