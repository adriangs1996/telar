-- The colorscheme of the window showing this pane. `telar pane theme` gives the theme the window
-- shows: the terminal's colors and the colors of its syntax and chrome roles. Its palette paints
-- through tint, so the editor reads as telar does, on any machine the pane runs on.
local M = {}

local tint = require("telar.tint")

M.name = "telar"

-- Groups a syntax role styles: its italic and bold flags apply to them all. The builtin roles
-- also give their color, which tint's palette has no key for.
local role_groups = {
  plain = { "Identifier", "@variable" },
  keyword = {
    "Keyword",
    "Statement",
    "Conditional",
    "Repeat",
    "Exception",
    "@keyword",
    "@keyword.function",
    "@keyword.return",
    "@keyword.operator",
    "@keyword.conditional",
    "@keyword.repeat",
    "@keyword.exception",
    "@keyword.import",
  },
  string = { "String", "@string" },
  number = { "Number", "Float", "@number", "@number.float" },
  comment = { "Comment", "@comment" },
  constant = { "Constant", "@constant" },
  builtin_constant = { "Boolean", "@boolean", "@constant.builtin" },
  builtin = { "@function.builtin", "@variable.builtin", "@type.builtin", "@module.builtin" },
  func = { "Function", "@function", "@function.call", "@function.method", "@function.method.call" },
  type = { "Type", "@type", "@type.definition" },
  parameter = { "@variable.parameter" },
  property = { "@property", "@variable.member" },
  namespace = { "@module", "@namespace" },
  operator = { "Operator", "@operator" },
  punctuation = { "Delimiter", "@punctuation", "@punctuation.bracket", "@punctuation.delimiter" },
}

local colored_roles = { builtin_constant = true, builtin = true }

local ansi_names = {
  "black",
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
  "brightBlack",
  "brightRed",
  "brightGreen",
  "brightYellow",
  "brightBlue",
  "brightMagenta",
  "brightCyan",
  "brightWhite",
}

local function luminance(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

-- Whether `theme` holds every color the palette reads: a window older than the editor colors
-- gives only the terminal's.
function M.complete(theme)
  return type(theme) == "table"
    and type(theme.foreground) == "string"
    and type(theme.background) == "string"
    and type(theme.ansi) == "table"
    and #theme.ansi == #ansi_names
    and type(theme.syntax) == "table"
    and type(theme.chrome) == "table"
end

-- The tint palette of `theme`, as `telar pane theme` prints it. tint's roles that telar's theme
-- has no role for take the nearest one: control flow and tags are keywords, interfaces types,
-- regular expressions strings, escapes builtin constants, attributes and decorators builtins.
function M.palette(theme)
  local s = {}
  for role, style in pairs(theme.syntax) do
    s[role] = style.color
  end

  local ui = theme.chrome
  local fg, bg = theme.foreground, theme.background
  local ansi = {}
  for index, name in ipairs(ansi_names) do
    ansi[name] = theme.ansi[index]
  end

  return {
    bg = { editor = bg, window = ui.panel_bg, inset = ui.surface0, elevated = bg },
    fg = { base = fg, fg1 = ui.text, fg2 = ui.subtext0, fg3 = ui.overlay1, fg4 = ui.overlay0 },
    border = {
      window = ui.panel_bg,
      editor = ui.surface0,
      indentGuide = ui.surface0,
      indentGuideActive = ui.surface1,
      inset = ui.surface0,
      elevated = ui.surface1,
    },
    accent = { primary = ui.accent, link = ui.accent, subtle = ui.surface1, contrast = bg },
    states = { success = ui.green, danger = ui.red, warn = ui.yellow, info = ui.blue, merge = ui.mauve },
    syntax = {
      variable = s.plain,
      func = s.func,
      call = s.func,
      type = s.type,
      type_definition = s.type,
      interface = s.type,
      keyword = s.keyword,
      control = s.keyword,
      tag = s.keyword,
      operator = s.operator,
      namespace = s.namespace,
      punctuation = s.punctuation,
      string = s.string,
      regexp = s.string,
      escape = s.builtin_constant,
      number = s.number,
      constant = s.constant,
      parameter = s.parameter,
      property = s.property,
      comment = s.comment,
      doc_comment = s.comment,
      attribute = s.builtin,
      decorator = s.builtin,
      invalid = ui.red,
    },
    ansi = ansi,
  }
end

-- Paints `theme`. `options` passes on to tint (`transparent`, `transparent_floats`,
-- `italic_comments`): transparent by default, so the window's background and its opacity show.
function M.apply(theme, options)
  local palette = M.palette(theme)

  tint.palette[M.name] = palette
  tint.setup(vim.tbl_extend("force", { transparent = true }, options or {}, {
    variant = M.name,
    name = M.name,
    background = luminance(theme.background) > 0.5 and "light" or "dark",
  }))

  for role, groups in pairs(role_groups) do
    local style = theme.syntax[role]
    if style then
      for _, group in ipairs(groups) do
        local spec = vim.api.nvim_get_hl(0, { name = group, link = false })
        spec.italic, spec.bold = style.italic or nil, style.bold or nil
        if colored_roles[role] then
          spec.fg = style.color
        end

        vim.api.nvim_set_hl(0, group, spec)
      end
    end
  end

  if theme.cursor then
    for _, group in ipairs({ "Cursor", "lCursor", "CursorIM", "TermCursor" }) do
      vim.api.nvim_set_hl(0, group, { fg = theme.background, bg = theme.cursor })
    end
  end

  M.current = theme
  vim.api.nvim_exec_autocmds("User", { pattern = "TelarTheme", modeline = false })
end

local function decode(result)
  if result.code ~= 0 or not result.stdout or result.stdout == "" then
    return nil
  end

  local ok, theme = pcall(vim.json.decode, result.stdout, { luanil = { object = true, array = true } })
  return ok and M.complete(theme) and theme or nil
end

local function command()
  return { require("telar").bin(), "pane", "theme", "--current", "--json" }
end

-- The window's theme now, or nil when no window owns the pane or the runtime cannot say.
function M.read()
  return decode(vim.system(command(), { text = true }):wait())
end

local fetching, again = false, false

-- Reads the window's theme without blocking and paints it when it differs from the one shown.
-- A refresh asked while one runs runs once more after it.
function M.refresh(options)
  if fetching then
    again = true
    return
  end

  fetching = true
  vim.system(command(), { text = true }, function(result)
    vim.schedule(function()
      fetching = false
      local theme = decode(result)
      if theme and (vim.g.colors_name ~= M.name or not vim.deep_equal(theme, M.current)) then
        M.apply(theme, options)
      end

      if again then
        again = false
        M.refresh(options)
      end
    end)
  end)
end

-- Follows the window's theme: Neovim asks the terminal for its background again when telar
-- announces new colors (DEC mode 2031), and that answer brings the rest of the theme.
function M.follow(options)
  local group = vim.api.nvim_create_augroup("TelarTheme", { clear = true })

  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(event)
      local sequence = event.data and event.data.sequence or ""
      if sequence:match("^\27%]11;") then
        M.refresh(options)
      end
    end,
  })

  M.refresh(options)
end

return M
