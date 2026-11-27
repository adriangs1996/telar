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

-- Plugins that cannot work in telar's window, by the module they are required by: each draws
-- what the window already draws natively. A configuration that loads one, as LazyVim does
-- noice.nvim, gets an inert module in its place, which takes any call and does nothing, and the
-- person is told once. package.preload is where require looks first, before the loaders
-- lazy.nvim and vim.loader put ahead of the runtimepath's.
local incompatible = {
  noice = { plugin = "noice.nvim", reason = "telar draws the command line, the messages and the completion menu itself" },
}

local inert
inert = setmetatable({}, {
  __index = function()
    return inert
  end,
  __call = function() end,
})

local told = {}
setmetatable(package.preload, {
  __index = function(_, name)
    local known = incompatible[name:match("^[^.]+")]
    if not known then
      return nil
    end

    return function()
      if not told[known.plugin] then
        told[known.plugin] = true
        vim.schedule(function()
          vim.notify(known.plugin .. " is off in telar: " .. known.reason .. ".", vim.log.levels.WARN)
        end)
      end

      return inert
    end
  end,
})

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

-- What Neovim's own tab line does not say of a tab page, by the buffer of its window in use,
-- nor of a listed buffer: whether it has changes not written, and how many warnings and
-- errors its diagnostics have. Each list is told when it changes, and holds no more than the
-- runtime takes.
local most_marks = 128
local marked = {}
local function tell_marks(method, entries)
  local marks, key = {}, {}
  for _, entry in ipairs(entries) do
    local modified = vim.bo[entry[2]].modified
    local diagnostics = #vim.diagnostic.get(entry[2], { severity = { min = vim.diagnostic.severity.WARN } })
    if (modified or diagnostics > 0) and #marks < most_marks then
      marks[#marks + 1] = { entry[1], modified, diagnostics }
      key[#key + 1] = entry[1] .. (modified and "+" or "-") .. diagnostics
    end
  end

  local now = table.concat(key, ",")
  if now ~= marked[method] then
    marked[method] = now
    vim.rpcnotify(channel, method, marks)
  end
end

local function tell_tabs()
  local pages, buffers = {}, {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local found, window = pcall(vim.api.nvim_tabpage_get_win, tab)
    if found then
      pages[#pages + 1] = { tab, vim.api.nvim_win_get_buf(window) }
    end
  end

  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buffer].buflisted then
      buffers[#buffers + 1] = { buffer, buffer }
    end
  end

  tell_marks("telar_tabs", pages)
  tell_marks("telar_buffer_marks", buffers)
end

-- The files the listed buffers show, for what lists files beside the editor: each by its
-- absolute path, with whether its buffer has changes not written and whether it is the one
-- being edited. Told when the list changes, and no more of it than the runtime takes.
local most_files, most_file_bytes = 64, 32768
local filed = nil
local function tell_files()
  local files, key, bytes = {}, {}, 0
  local edited = vim.api.nvim_get_current_buf()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if vim.bo[buffer].buflisted and vim.bo[buffer].buftype == "" and name:sub(1, 1) == "/" and #files < most_files and bytes + #name <= most_file_bytes then
      local modified = vim.bo[buffer].modified
      files[#files + 1] = { name, modified, buffer == edited }
      key[#key + 1] = name .. (modified and "+" or "-") .. (buffer == edited and "*" or "")
      bytes = bytes + #name
    end
  end

  local now = table.concat(key, "\n")
  if now ~= filed then
    filed = now
    vim.rpcnotify(channel, "telar_files", files)
  end
end

vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufEnter", "BufWritePost", "WinEnter", "TabEnter", "TabClosed", "DiagnosticChanged", "BufAdd", "BufDelete", "BufWipeout", "BufFilePost", "VimEnter" }, {
  group = group,
  callback = function()
    vim.schedule(function()
      tell_tabs()
      tell_files()
    end)
  end,
})

-- A file the explorer moved, or a directory with what is below it: the buffer that shows it
-- shows it under its new name, with its changes and its undo, and nothing is written for it.
-- One without changes reads the file again where it is now, so Neovim knows it as written; one
-- with changes keeps them, and its first `:w` there asks for `!`, as after `:file`.
local function rename(buffer, name, moved)
  if not pcall(vim.api.nvim_buf_set_name, buffer, moved) then
    return
  end

  -- Neovim keeps the old name in a buffer of its own, for the alternate file. The file is not
  -- there any more, and that buffer would be in the way of the name when the move is undone.
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buffer and vim.api.nvim_buf_get_name(other) == name and not vim.api.nvim_buf_is_loaded(other) then
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end
  end

  if not vim.bo[buffer].modified and vim.api.nvim_buf_is_loaded(buffer) then
    vim.api.nvim_buf_call(buffer, function()
      local view = vim.fn.winsaveview()
      pcall(vim.cmd, "silent! keepalt edit")
      vim.fn.winrestview(view)
    end)
  end
end

-- Neovim names a buffer by the real path of its directory, and the explorer may have reached
-- the file through a symbolic link: the path as Neovim would name it.
local function named(path)
  local head, tail = path:match("^(.*)/([^/]*)$")
  local real = head and vim.uv.fs_realpath(head == "" and "/" or head)
  if not real then
    return path
  end

  return (real == "/" and "" or real) .. "/" .. tail
end

function _G.__telar_moved(from, to)
  from = named(from)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_get_name(buffer) or ""
    if vim.bo[buffer].buftype == "" and (name == from or name:sub(1, #from + 1) == from .. "/") then
      rename(buffer, name, to .. name:sub(#from + 1))
    end
  end

  vim.schedule(function()
    tell_tabs()
    tell_files()
  end)
end

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

-- The command line as the window draws it. Neovim sends `:` uncolored, so its text is parsed
-- here as Vim script, with the Lua of `:lua` and the shell command of `:!` in their own
-- languages, and sent with what it completes: `[text, [[bytes, rgb or -1, attributes]...],
-- completion type]`. A run's attributes are bold 1 and italic 2.
local capture_styles = {}
local function capture_style(capture, language)
  local key = capture .. "." .. language
  local found = capture_styles[key]
  if found == nil then
    found = false
    -- `@function.call.lua` falls back as the highlighter does: `@function.call`, `@function`.
    local name = "@" .. key
    while name do
      local highlight = vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
      if highlight.fg then
        found = { highlight.fg, (highlight.bold and 1 or 0) + (highlight.italic and 2 or 0) }
        break
      end

      name = name:match("^(.+)%.[^.]+$")
    end

    capture_styles[key] = found
  end

  return found or nil
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    capture_styles = {}
  end,
})

-- The styles of a text's bytes, from one parse of it in `language`, offset by `from` bytes.
local function color_bytes(styles, text, language, from)
  local parsed, parser = pcall(vim.treesitter.get_string_parser, text, language)
  if not parsed then
    return
  end

  parser:parse(true)
  parser:for_each_tree(function(tree, tree_language)
    local name = tree_language:lang()
    local query = vim.treesitter.query.get(name, "highlights")
    if query == nil then
      return
    end

    -- A capture later in a tree, or in an injected one, is the narrower: it wins.
    for id, node in query:iter_captures(tree:root(), text) do
      local capture = query.captures[id]
      local style = capture:sub(1, 1) ~= "_" and capture ~= "spell" and capture ~= "nospell" and capture_style(capture, name)
      if style then
        local _, _, first, _, _, last = node:range(true)
        for byte = first + 1, math.min(last, #text) do
          styles[from + byte] = style
        end
      end
    end
  end)
end

local maximum_colored_bytes = 1024
local function cmdline_runs(text)
  if #text > maximum_colored_bytes then
    return {}
  end

  local styles = {}
  color_bytes(styles, text, "vim", 0)
  -- Vim script has no grammar for a shell command: a shell's, when one is installed.
  local bang = text:match("^%s*!()")
  if bang and pcall(vim.treesitter.language.add, "bash") then
    color_bytes(styles, text:sub(bang), "bash", bang - 1)
  end

  local runs, style, bytes = {}, nil, 0
  for byte = 1, #text do
    if styles[byte] ~= style and bytes > 0 then
      runs[#runs + 1] = { bytes, style and style[1] or -1, style and style[2] or 0 }
      bytes = 0
    end

    style = styles[byte]
    bytes = bytes + 1
  end

  if bytes > 0 and (style or #runs > 0) then
    runs[#runs + 1] = { bytes, style and style[1] or -1, style and style[2] or 0 }
  end

  return runs
end

local function tell_cmdline()
  if vim.fn.getcmdtype() ~= ":" then
    return
  end

  local text = vim.fn.getcmdline()
  local colored, runs = pcall(cmdline_runs, text)
  vim.rpcnotify(channel, "telar_cmdline", text, colored and runs or {}, vim.fn.getcmdcompltype())
end

vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineChanged" }, { group = group, callback = tell_cmdline })

-- The first parse loads the grammars and their queries, which takes a moment: it is taken
-- once Neovim is idle after starting, not on the first key typed after `:`.
vim.api.nvim_create_autocmd("UIEnter", {
  group = group,
  once = true,
  callback = function()
    vim.defer_fn(function()
      pcall(cmdline_runs, "lua vim.fn.has('nvim')")
    end, 1500)
  end,
})

-- `:Telar files`, `:Telar grep` and `:Telar buffers` ask the window for its picker, and
-- `:Telar explore` for its explorer, on the directory of the file being edited with that file
-- selected.
local sources = { "files", "grep", "buffers" }
vim.api.nvim_create_user_command("Telar", function(command)
  if vim.tbl_contains(sources, command.args) then
    vim.rpcnotify(channel, "telar_pick", command.args)
  elseif command.args == "explore" then
    vim.rpcnotify(channel, "telar_explore", vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or "")
  else
    vim.notify("Telar: files, grep, buffers or explore", vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  complete = function()
    return { "files", "grep", "buffers", "explore" }
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

-- A file shown in a float that takes no focus, over the cells a picker leaves for it, with
-- what a search matched on its line marked in that window alone. The buffers it loads only to
-- show are dropped when it closes.
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

function _G.__telar_preview(path, line, row, column, columns, rows, match_column, match_bytes)
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
  vim.fn.clearmatches(preview)
  if line > 0 and (match_column or 0) > 0 and (match_bytes or 0) > 0 then
    vim.fn.matchaddpos("Search", { { line, match_column, match_bytes } }, 10, -1, { window = preview })
  end

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
