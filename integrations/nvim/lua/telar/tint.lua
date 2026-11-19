-- tint: the highlight engine telar's colorscheme paints with. A palette registered in
-- `M.palette` under a colorscheme name holds every color it reads; `telar.theme` builds the one
-- for the theme of the window showing the pane.

local M = {}

local palettes = {}

M.palette = palettes

-- Palette registered under `variant`, or the one applied last when none is given.
local function palette(variant)
  variant = variant or vim.g.tint_current_variant
  return assert(palettes[variant], "tint: unknown palette " .. tostring(variant)), variant
end

local function hex_to_rgb(hex)
  hex = hex:gsub("#", "")
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local function blend(fg, bg, alpha)
  local fr, fg_, fb = hex_to_rgb(fg)
  local br, bg_, bb = hex_to_rgb(bg)
  local function channel(a, b)
    return math.floor((a * alpha) + (b * (1 - alpha)) + 0.5)
  end
  return string.format("#%02x%02x%02x", channel(fr, br), channel(fg_, bg_), channel(fb, bb))
end

local function set(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

local function link(group, target)
  set(group, { link = target })
end

local function set_terminal_colors(c)
  local ansi = {
    c.ansi.black,
    c.ansi.red,
    c.ansi.green,
    c.ansi.yellow,
    c.ansi.blue,
    c.ansi.magenta,
    c.ansi.cyan,
    c.ansi.white,
    c.ansi.brightBlack,
    c.ansi.brightRed,
    c.ansi.brightGreen,
    c.ansi.brightYellow,
    c.ansi.brightBlue,
    c.ansi.brightMagenta,
    c.ansi.brightCyan,
    c.ansi.brightWhite,
  }

  for index, color in ipairs(ansi) do
    vim.g["terminal_color_" .. (index - 1)] = color
  end
end

local function resolve_options(opts)
  opts = vim.tbl_deep_extend("force", {
    transparent = true,
    italic_comments = false,
  }, opts or {})
  local _, variant = palette(opts.variant)
  opts.variant = variant
  opts.name = opts.name or variant

  return opts
end

-- Plugin themes are built after setup, sometimes again on ColorScheme.
local transparent_by_variant = {}

local function is_transparent(variant)
  return transparent_by_variant[variant] ~= false
end

function M.lualine_theme(variant)
  local c
  c, variant = palette(variant)

  local theme = {
    normal = {
      a = { fg = c.accent.contrast, bg = c.accent.primary, gui = "bold" },
      b = { fg = c.accent.primary, bg = c.bg.inset },
      c = { fg = c.fg.fg2, bg = c.bg.window },
    },
    insert = {
      a = { fg = c.bg.editor, bg = c.states.success, gui = "bold" },
      b = { fg = c.states.success, bg = c.bg.inset },
    },
    visual = {
      a = { fg = c.bg.editor, bg = c.syntax.keyword, gui = "bold" },
      b = { fg = c.syntax.keyword, bg = c.bg.inset },
    },
    replace = {
      a = { fg = c.bg.editor, bg = c.states.danger, gui = "bold" },
      b = { fg = c.states.danger, bg = c.bg.inset },
    },
    command = {
      a = { fg = c.bg.editor, bg = c.states.warn, gui = "bold" },
      b = { fg = c.states.warn, bg = c.bg.inset },
    },
    terminal = {
      a = { fg = c.bg.editor, bg = c.syntax.type, gui = "bold" },
      b = { fg = c.syntax.type, bg = c.bg.inset },
    },
    inactive = {
      a = { fg = c.fg.fg4, bg = c.bg.window },
      b = { fg = c.fg.fg4, bg = c.bg.window },
      c = { fg = c.fg.fg3, bg = c.bg.window },
    },
  }

  if is_transparent(variant) then
    for mode, sections in pairs(theme) do
      -- Inverted mode badges need their accent as text once the fill is gone.
      if mode ~= "inactive" then
        sections.a.fg = sections.a.bg
      end
      for _, spec in pairs(sections) do
        spec.bg = "NONE"
      end
    end
  end

  return theme
end

function M.bufferline_highlights(variant)
  local c
  c, variant = palette(variant)

  local transparent = is_transparent(variant)
  local fill = transparent and "NONE" or c.bg.elevated
  local tab = fill
  local selected = transparent and "NONE" or c.bg.editor
  local visible = fill
  local separator = transparent and c.border.editor or fill
  local muted = c.fg.fg3
  local subtle = c.fg.fg4

  return {
    fill = { bg = fill },
    background = { fg = muted, bg = tab },
    tab = { fg = muted, bg = tab },
    tab_selected = { fg = c.fg.base, bg = selected, bold = true },
    tab_separator = { fg = separator, bg = tab },
    tab_separator_selected = { fg = separator, bg = selected },
    tab_close = { fg = subtle, bg = tab },
    close_button = { fg = subtle, bg = tab },
    close_button_visible = { fg = muted, bg = visible },
    close_button_selected = { fg = muted, bg = selected },
    buffer_visible = { fg = c.fg.fg2, bg = visible },
    buffer_selected = { fg = c.fg.base, bg = selected, bold = true, italic = false },
    numbers = { fg = subtle, bg = tab },
    numbers_visible = { fg = muted, bg = visible },
    numbers_selected = { fg = c.fg.fg2, bg = selected, bold = true },
    diagnostic = { fg = subtle, bg = tab },
    diagnostic_visible = { fg = muted, bg = visible },
    diagnostic_selected = { fg = c.fg.fg2, bg = selected, bold = true },
    hint = { fg = c.accent.primary, sp = c.accent.primary, bg = tab },
    hint_visible = { fg = c.accent.primary, bg = visible },
    hint_selected = { fg = c.accent.primary, sp = c.accent.primary, bg = selected, bold = true },
    hint_diagnostic = { fg = c.accent.primary, sp = c.accent.primary, bg = tab },
    hint_diagnostic_visible = { fg = c.accent.primary, bg = visible },
    hint_diagnostic_selected = { fg = c.accent.primary, sp = c.accent.primary, bg = selected, bold = true },
    info = { fg = c.states.info, sp = c.states.info, bg = tab },
    info_visible = { fg = c.states.info, bg = visible },
    info_selected = { fg = c.states.info, sp = c.states.info, bg = selected, bold = true },
    info_diagnostic = { fg = c.states.info, sp = c.states.info, bg = tab },
    info_diagnostic_visible = { fg = c.states.info, bg = visible },
    info_diagnostic_selected = { fg = c.states.info, sp = c.states.info, bg = selected, bold = true },
    warning = { fg = c.states.warn, sp = c.states.warn, bg = tab },
    warning_visible = { fg = c.states.warn, bg = visible },
    warning_selected = { fg = c.states.warn, sp = c.states.warn, bg = selected, bold = true },
    warning_diagnostic = { fg = c.states.warn, sp = c.states.warn, bg = tab },
    warning_diagnostic_visible = { fg = c.states.warn, bg = visible },
    warning_diagnostic_selected = { fg = c.states.warn, sp = c.states.warn, bg = selected, bold = true },
    error = { fg = c.states.danger, sp = c.states.danger, bg = tab },
    error_visible = { fg = c.states.danger, bg = visible },
    error_selected = { fg = c.states.danger, sp = c.states.danger, bg = selected, bold = true },
    error_diagnostic = { fg = c.states.danger, sp = c.states.danger, bg = tab },
    error_diagnostic_visible = { fg = c.states.danger, bg = visible },
    error_diagnostic_selected = { fg = c.states.danger, sp = c.states.danger, bg = selected, bold = true },
    modified = { fg = c.states.warn, bg = tab },
    modified_visible = { fg = c.states.warn, bg = visible },
    modified_selected = { fg = c.states.warn, bg = selected },
    duplicate = { fg = muted, bg = tab, italic = false },
    duplicate_visible = { fg = muted, bg = visible, italic = false },
    duplicate_selected = { fg = c.fg.fg2, bg = selected, italic = false },
    separator = { fg = separator, bg = tab },
    separator_visible = { fg = separator, bg = visible },
    separator_selected = { fg = separator, bg = selected },
    indicator_visible = { fg = separator, bg = visible },
    indicator_selected = { fg = c.accent.primary, bg = selected, sp = c.accent.primary },
    pick = { fg = c.states.warn, bg = tab, bold = true },
    pick_visible = { fg = c.states.warn, bg = visible, bold = true },
    pick_selected = { fg = c.states.warn, bg = selected, bold = true },
    offset_separator = { fg = c.border.elevated, bg = fill },
    trunc_marker = { fg = subtle, bg = fill },
  }
end

function M.setup(opts)
  opts = resolve_options(opts)
  transparent_by_variant[opts.variant] = opts.transparent
  local c = palettes[opts.variant]
  local s = c.syntax
  -- Optional roles. Without them, calls share the definition color and type
  -- definitions share the type color.
  local call = s.call or s.func
  local type_definition = s.type_definition or s.type
  -- Control flow (return, if, loops, exceptions) and documentation comments fall back to
  -- keywords and comments.
  local control = s.control or s.keyword
  local doc_comment = s.doc_comment or s.comment
  local is_dark = opts.background ~= "light"

  vim.o.termguicolors = true
  vim.o.background = is_dark and "dark" or "light"

  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end
  vim.g.colors_name = opts.name
  vim.g.tint_current_variant = opts.variant

  local bg_editor = opts.transparent and "NONE" or c.bg.editor
  local bg_window = opts.transparent and "NONE" or c.bg.window
  -- Popup surfaces can stay opaque independently of the editor background.
  local bg_elevated = opts.transparent and opts.transparent_floats ~= false and "NONE" or c.bg.elevated
  local visual = blend(c.accent.primary, c.bg.editor, is_dark and 0.30 or 0.18)
  local cursorline = blend(c.accent.subtle, c.bg.editor, 0.55)
  local hover = blend(c.accent.subtle, c.bg.editor, 0.35)
  local selection = is_dark and c.accent.subtle or blend(c.accent.subtle, c.bg.editor, 0.80)
  local search = blend(c.states.warn, c.bg.editor, is_dark and 0.35 or 0.30)
  local incsearch = blend(c.states.warn, c.bg.editor, is_dark and 0.80 or 0.65)
  local diff_add = blend(c.states.success, c.bg.editor, is_dark and 0.18 or 0.20)
  local diff_change = blend(c.accent.primary, c.bg.editor, is_dark and 0.16 or 0.18)
  local diff_delete = blend(c.states.danger, c.bg.editor, is_dark and 0.18 or 0.20)
  local diff_text = blend(c.states.info, c.bg.editor, is_dark and 0.32 or 0.28)

  set_terminal_colors(c)

  -- Core editor UI
  set("Normal", { fg = c.fg.base, bg = bg_editor })
  set("NormalNC", { fg = c.fg.base, bg = bg_editor })
  set("NormalFloat", { fg = c.fg.base, bg = bg_elevated })
  set("FloatBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("FloatTitle", { fg = c.fg.base, bg = bg_elevated, bold = true })
  set("EndOfBuffer", { fg = c.bg.editor, bg = bg_editor })
  set("SignColumn", { fg = c.fg.fg3, bg = bg_editor })
  set("FoldColumn", { fg = c.fg.fg3, bg = bg_editor })
  set("LineNr", { fg = c.fg.fg3, bg = bg_editor })
  set("LineNrAbove", { fg = c.fg.fg4, bg = bg_editor })
  set("LineNrBelow", { fg = c.fg.fg4, bg = bg_editor })
  set("CursorLineNr", { fg = c.fg.fg2, bg = cursorline })
  set("CursorLine", { bg = cursorline })
  set("CursorColumn", { bg = cursorline })
  set("ColorColumn", { bg = c.bg.window })
  set("Conceal", { fg = c.fg.fg3, bg = bg_editor })
  set("Cursor", { fg = c.bg.editor, bg = c.accent.primary })
  set("lCursor", { fg = c.bg.editor, bg = c.accent.primary })
  set("CursorIM", { fg = c.bg.editor, bg = c.accent.primary })
  set("TermCursor", { fg = c.bg.editor, bg = c.accent.primary })
  set("TermCursorNC", { fg = c.fg.fg3, bg = c.border.editor })
  set("Visual", { bg = visual })
  set("VisualNOS", { bg = visual })
  set("Search", { fg = c.fg.base, bg = search })
  set("IncSearch", { fg = c.bg.editor, bg = incsearch })
  set("CurSearch", { fg = c.bg.editor, bg = incsearch })
  set("Substitute", { fg = c.bg.editor, bg = c.states.warn })
  set("MatchParen", { fg = c.accent.primary, bg = hover, bold = true })
  set("Directory", { fg = c.accent.primary })
  set("Title", { fg = c.fg.base, bold = true })
  set("ErrorMsg", { fg = c.states.danger })
  set("WarningMsg", { fg = c.states.warn })
  set("MoreMsg", { fg = c.states.success })
  set("ModeMsg", { fg = c.fg.fg2 })
  set("Question", { fg = c.states.success })
  set("NonText", { fg = c.fg.fg4 })
  set("SpecialKey", { fg = c.fg.fg4 })
  set("Whitespace", { fg = c.border.indentGuide })
  set("Folded", { fg = c.fg.fg3, bg = bg_window })
  set("QuickFixLine", { fg = c.fg.base, bg = selection })
  set("WinSeparator", { fg = c.border.window, bg = bg_editor })
  set("VertSplit", { fg = c.border.window, bg = bg_editor })
  set("StatusLine", { fg = c.fg.fg2, bg = bg_window })
  set("StatusLineNC", { fg = c.fg.fg3, bg = bg_window })
  set("WinBar", { fg = c.fg.fg2, bg = bg_editor })
  set("WinBarNC", { fg = c.fg.fg3, bg = bg_editor })
  set("TabLine", { fg = c.fg.fg3, bg = bg_window })
  set("TabLineSel", { fg = c.fg.base, bg = bg_editor })
  set("TabLineFill", { bg = bg_window })
  set("Pmenu", { fg = c.fg.base, bg = c.bg.inset })
  set("PmenuSel", { fg = c.fg.base, bg = selection })
  set("PmenuKind", { fg = s.type, bg = c.bg.inset })
  set("PmenuKindSel", { fg = s.type, bg = selection })
  set("PmenuExtra", { fg = c.fg.fg3, bg = c.bg.inset })
  set("PmenuExtraSel", { fg = c.fg.fg2, bg = selection })
  set("PmenuSbar", { bg = c.bg.window })
  set("PmenuThumb", { bg = c.fg.fg4 })
  set("WildMenu", { fg = c.fg.base, bg = selection })
  set("MsgArea", { fg = c.fg.base, bg = bg_editor })
  set("MsgSeparator", { fg = c.border.window, bg = bg_editor })

  -- Diffs and diagnostics
  set("DiffAdd", { fg = c.states.success, bg = diff_add })
  set("DiffChange", { fg = c.accent.primary, bg = diff_change })
  set("DiffDelete", { fg = c.states.danger, bg = diff_delete })
  set("DiffText", { fg = c.states.info, bg = diff_text })
  set("Added", { fg = c.states.success })
  set("Changed", { fg = c.accent.primary })
  set("Removed", { fg = c.states.danger })
  set("DiagnosticError", { fg = c.states.danger })
  set("DiagnosticWarn", { fg = c.states.warn })
  set("DiagnosticInfo", { fg = c.states.info })
  set("DiagnosticHint", { fg = c.accent.primary })
  set("DiagnosticOk", { fg = c.states.success })
  set("DiagnosticVirtualTextError", { fg = c.states.danger, bg = blend(c.states.danger, c.bg.editor, 0.12) })
  set("DiagnosticVirtualTextWarn", { fg = c.states.warn, bg = blend(c.states.warn, c.bg.editor, 0.12) })
  set("DiagnosticVirtualTextInfo", { fg = c.states.info, bg = blend(c.states.info, c.bg.editor, 0.12) })
  set("DiagnosticVirtualTextHint", { fg = c.accent.primary, bg = blend(c.accent.primary, c.bg.editor, 0.12) })
  set("DiagnosticUnderlineError", { sp = c.states.danger, undercurl = true })
  set("DiagnosticUnderlineWarn", { sp = c.states.warn, undercurl = true })
  set("DiagnosticUnderlineInfo", { sp = c.states.info, undercurl = true })
  set("DiagnosticUnderlineHint", { sp = c.accent.primary, undercurl = true })
  set("DiagnosticFloatingError", { fg = c.states.danger, bg = bg_elevated })
  set("DiagnosticFloatingWarn", { fg = c.states.warn, bg = bg_elevated })
  set("DiagnosticFloatingInfo", { fg = c.states.info, bg = bg_elevated })
  set("DiagnosticFloatingHint", { fg = c.accent.primary, bg = bg_elevated })
  set("DiagnosticSignError", { fg = c.states.danger, bg = bg_editor })
  set("DiagnosticSignWarn", { fg = c.states.warn, bg = bg_editor })
  set("DiagnosticSignInfo", { fg = c.states.info, bg = bg_editor })
  set("DiagnosticSignHint", { fg = c.accent.primary, bg = bg_editor })

  -- Vim syntax groups
  set("Comment", { fg = s.comment, italic = opts.italic_comments })
  set("Constant", { fg = s.constant })
  set("String", { fg = s.string })
  set("Character", { fg = s.string })
  set("Number", { fg = s.number })
  set("Boolean", { fg = s.number })
  set("Float", { fg = s.number })
  set("Identifier", { fg = s.variable })
  set("Function", { fg = s.func })
  set("Interface", { fg = s.interface })
  set("Statement", { fg = s.keyword })
  set("Conditional", { fg = control })
  set("Repeat", { fg = control })
  set("Label", { fg = s.tag })
  set("Operator", { fg = s.operator })
  set("Keyword", { fg = s.keyword })
  set("Exception", { fg = control })
  set("PreProc", { fg = s.namespace })
  set("Include", { fg = s.func })
  set("Define", { fg = s.keyword })
  set("Macro", { fg = s.constant })
  set("PreCondit", { fg = s.keyword })
  set("Type", { fg = s.type })
  set("StorageClass", { fg = s.keyword })
  set("Structure", { fg = s.type })
  set("Typedef", { fg = s.type })
  set("Special", { fg = s.escape })
  set("SpecialChar", { fg = s.escape })
  set("Tag", { fg = s.tag })
  set("Delimiter", { fg = s.punctuation })
  set("SpecialComment", { fg = s.comment })
  set("Debug", { fg = s.constant })
  set("Underlined", { fg = c.accent.link, underline = true })
  set("Ignore", { fg = c.fg.fg4 })
  set("Error", { fg = c.states.danger })
  set("Todo", { fg = c.states.warn, bg = blend(c.states.warn, c.bg.editor, 0.18), bold = true })

  -- Tree-sitter captures
  link("@comment", "Comment")
  set("@comment.documentation", { fg = doc_comment, italic = opts.italic_comments })
  set("@comment.error", { fg = c.states.danger })
  set("@comment.warning", { fg = c.states.warn })
  set("@comment.todo", { fg = c.states.warn, bold = true })
  set("@comment.note", { fg = c.states.info })
  set("@variable", { fg = s.variable })
  set("@variable.builtin", { fg = s.namespace })
  set("@variable.parameter", { fg = s.parameter, italic = true })
  set("@variable.member", { fg = s.property })
  set("@constant", { fg = s.constant })
  set("@constant.builtin", { fg = s.number })
  set("@constant.macro", { fg = s.constant })
  set("@module", { fg = s.namespace })
  set("@module.builtin", { fg = s.namespace })
  set("@label", { fg = s.tag })
  link("@string", "String")
  set("@string.documentation", { fg = s.doc_comment or s.string })
  set("@string.regexp", { fg = s.regexp })
  set("@string.escape", { fg = s.escape })
  set("@string.special", { fg = s.escape })
  set("@string.special.symbol", { fg = s.property })
  set("@character", { fg = s.string })
  set("@character.special", { fg = s.escape })
  link("@number", "Number")
  link("@boolean", "Boolean")
  link("@float", "Float")
  set("@type", { fg = s.type })
  set("@type.builtin", { fg = s.keyword })
  set("@type.definition", { fg = type_definition })
  set("@attribute", { fg = s.attribute })
  set("@property", { fg = s.property })
  set("@function", { fg = s.func })
  set("@function.builtin", { fg = call })
  set("@function.call", { fg = call })
  set("@function.macro", { fg = s.constant })
  set("@function.method", { fg = s.func })
  set("@function.method.call", { fg = call })
  set("@constructor", { fg = s.type })
  link("@operator", "Operator")
  link("@keyword", "Keyword")
  set("@keyword.coroutine", { fg = s.keyword })
  set("@keyword.function", { fg = s.keyword })
  set("@keyword.operator", { fg = s.operator })
  set("@keyword.import", { fg = s.operator })
  set("@keyword.type", { fg = s.keyword })
  set("@keyword.modifier", { fg = s.keyword })
  set("@keyword.repeat", { fg = control })
  set("@keyword.return", { fg = control })
  set("@keyword.debug", { fg = s.keyword })
  set("@keyword.exception", { fg = control })
  set("@keyword.conditional", { fg = control })
  set("@keyword.conditional.ternary", { fg = control })
  set("@keyword.directive", { fg = s.namespace })
  set("@keyword.directive.define", { fg = s.constant })
  set("@punctuation.delimiter", { fg = s.punctuation })
  set("@punctuation.bracket", { fg = s.punctuation })
  set("@punctuation.special", { fg = s.punctuation })
  set("@tag", { fg = s.tag })
  set("@tag.builtin", { fg = s.tag })
  set("@tag.attribute", { fg = s.attribute })
  set("@tag.delimiter", { fg = s.punctuation })
  set("@markup.heading", { fg = s.tag, bold = true })
  set("@markup.strong", { fg = s.constant, bold = true })
  set("@markup.italic", { fg = s.keyword, italic = true })
  set("@markup.strikethrough", { strikethrough = true })
  set("@markup.underline", { underline = true })
  set("@markup.link", { fg = c.accent.link })
  set("@markup.link.label", { fg = s.func })
  set("@markup.link.url", { fg = c.accent.link, underline = true })
  set("@markup.raw", { fg = s.string })
  set("@markup.list", { fg = s.tag })
  set("@markup.quote", { fg = s.comment })
  set("@diff.plus", { fg = c.states.success })
  set("@diff.minus", { fg = c.states.danger })
  set("@diff.delta", { fg = c.accent.primary })
  link("@namespace", "@module")
  link("@field", "@variable.member")
  link("@method", "@function.method")
  link("@method.call", "@function.method.call")
  link("@parameter", "@variable.parameter")

  -- LSP semantic tokens
  link("@lsp.type.comment", "@comment")
  link("@lsp.type.string", "@string")
  link("@lsp.type.number", "@number")
  set("@lsp.type.regexp", { fg = s.regexp })
  link("@lsp.type.keyword", "@keyword")
  set("@lsp.typemod.keyword.controlFlow", { fg = control })
  set("@lsp.type.variable", { fg = s.variable })
  set("@lsp.type.parameter", { fg = s.parameter, italic = true })
  set("@lsp.type.property", { fg = s.property })
  set("@lsp.typemod.property.defaultLibrary", { fg = s.property, italic = true })
  -- Semantic tokens tag uses and definitions alike; the declaration and definition
  -- modifiers (higher priority) restore the definition colors.
  set("@lsp.type.function", { fg = call })
  set("@lsp.type.method", { fg = call })
  for _, modifier in ipairs({ "declaration", "definition" }) do
    for _, kind in ipairs({ "function", "method" }) do
      set("@lsp.typemod." .. kind .. "." .. modifier, { fg = s.func })
    end
    for _, kind in ipairs({ "class", "struct", "enum", "type" }) do
      set("@lsp.typemod." .. kind .. "." .. modifier, { fg = type_definition })
    end
    set("@lsp.typemod.interface." .. modifier, { fg = s.type_definition or s.interface })
  end
  set("@lsp.type.type", { fg = s.type })
  set("@lsp.type.class", { fg = s.type })
  set("@lsp.type.struct", { fg = s.type })
  set("@lsp.type.interface", { fg = s.type })
  set("@lsp.type.enum", { fg = s.type })
  set("@lsp.typemod.class.defaultLibrary", { fg = s.type })
  set("@lsp.type.enumMember", { fg = s.number })
  set("@lsp.type.namespace", { fg = s.namespace })
  set("@lsp.type.decorator", { fg = s.decorator })
  set("@lsp.type.macro", { fg = s.decorator })
  set("@lsp.mod.defaultLibrary", { fg = s.keyword })
  set("@lsp.typemod.type.defaultLibrary", { fg = s.type })
  -- set("@lsp.mod.readonly", { fg = s.constant })
  set("@lsp.typemod.variable.defaultLibrary", { fg = s.namespace })
  set("@lsp.typemod.variable.readonly", { fg = s.variable })
  set("@lsp.typemod.function.defaultLibrary", { fg = call })
  set("@lsp.typemod.method.defaultLibrary", { fg = call })
  set("@lsp.typemod.function", { fg = s.func })
  -- set("@lsp.typemod.variable.readonly", { fg = c.fg.fg1 })
  set("@lsp.typemod.interface", { fg = s.interface })
  set("@lsp.type.interface", { fg = s.interface })

  -- Indent guides
  set("IblIndent", { fg = c.border.indentGuide })
  set("IblScope", { fg = c.border.indentGuideActive })
  set("IndentBlanklineChar", { fg = c.border.indentGuide })
  set("IndentBlanklineContextChar", { fg = c.border.indentGuideActive })
  set("SnacksIndent", { fg = c.border.indentGuide })
  set("SnacksIndentScope", { fg = c.border.indentGuideActive })
  set("MiniIndentscopeSymbol", { fg = c.border.indentGuideActive })

  -- Completion
  set("CmpBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("CmpItemAbbr", { fg = c.fg.base })
  set("CmpItemAbbrDeprecated", { fg = c.fg.fg4, strikethrough = true })
  set("CmpItemAbbrMatch", { fg = c.accent.primary, bold = true })
  set("CmpItemAbbrMatchFuzzy", { fg = c.accent.primary, bold = true })
  set("CmpItemKind", { fg = s.type })
  set("CmpItemMenu", { fg = c.fg.fg3 })
  set("CmpItemKindFunction", { fg = s.func })
  set("CmpItemKindMethod", { fg = s.func })
  set("CmpItemKindConstructor", { fg = s.type })
  set("CmpItemKindClass", { fg = s.type })
  set("CmpItemKindInterface", { fg = s.type })
  set("CmpItemKindModule", { fg = s.namespace })
  set("CmpItemKindProperty", { fg = s.property })
  set("CmpItemKindField", { fg = s.property })
  set("CmpItemKindVariable", { fg = s.variable })
  set("CmpItemKindConstant", { fg = s.constant })
  set("CmpItemKindKeyword", { fg = s.keyword })
  set("CmpItemKindSnippet", { fg = s.decorator })
  set("CmpItemKindString", { fg = s.string })
  set("CmpItemKindNumber", { fg = s.number })
  set("CmpItemKindBoolean", { fg = s.number })
  set("CmpItemKindEnum", { fg = s.type })
  set("CmpItemKindEnumMember", { fg = s.operator })
  set("CmpItemKindOperator", { fg = s.operator })
  link("BlinkCmpMenu", "Pmenu")
  link("BlinkCmpMenuBorder", "FloatBorder")
  link("BlinkCmpMenuSelection", "PmenuSel")
  link("BlinkCmpDoc", "NormalFloat")
  link("BlinkCmpDocBorder", "FloatBorder")
  link("BlinkCmpSignatureHelp", "NormalFloat")
  link("BlinkCmpSignatureHelpBorder", "FloatBorder")
  link("BlinkCmpLabelMatch", "CmpItemAbbrMatch")
  link("BlinkCmpKind", "CmpItemKind")
  set("BlinkCmpLabel", { fg = c.fg.base })
  set("BlinkCmpLabelDescription", { fg = c.fg.fg3 })
  set("BlinkCmpLabelDetail", { fg = c.fg.fg3 })
  set("BlinkCmpLabelDeprecated", { fg = c.fg.fg4, strikethrough = true })
  set("BlinkCmpSource", { fg = c.fg.fg3 })
  set("BlinkCmpGhostText", { fg = c.fg.fg4, italic = true })
  set("BlinkCmpDocSeparator", { fg = c.border.elevated })
  set("BlinkCmpDocCursorLine", { bg = selection })
  set("BlinkCmpSignatureHelpActiveParameter", { fg = c.states.warn, bold = true })
  set("BlinkCmpScrollBarGutter", { bg = c.bg.window })
  set("BlinkCmpScrollBarThumb", { bg = c.fg.fg4 })
  set("BlinkCmpItemIdx", { fg = c.fg.fg4 })

  -- Telescope
  set("TelescopeNormal", { fg = c.fg.base, bg = bg_elevated })
  set("TelescopeBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("TelescopePromptNormal", { fg = c.fg.base, bg = c.bg.inset })
  set("TelescopePromptBorder", { fg = c.border.inset, bg = c.bg.inset })
  set("TelescopePromptTitle", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("TelescopePreviewTitle", { fg = c.bg.editor, bg = c.states.success, bold = true })
  set("TelescopeResultsTitle", { fg = c.bg.editor, bg = c.fg.fg4, bold = true })
  set("TelescopeSelection", { fg = c.fg.base, bg = selection })
  set("TelescopeMatching", { fg = c.accent.primary, bold = true })

  -- fzf-lua
  set("FzfLuaNormal", { fg = c.fg.base, bg = bg_elevated })
  set("FzfLuaBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("FzfLuaTitle", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("FzfLuaPreviewNormal", { fg = c.fg.base, bg = bg_editor })
  set("FzfLuaPreviewBorder", { fg = c.border.elevated, bg = bg_editor })
  set("FzfLuaPreviewTitle", { fg = c.bg.editor, bg = c.states.success, bold = true })
  set("FzfLuaCursor", { fg = c.bg.editor, bg = c.accent.primary })
  set("FzfLuaCursorLine", { fg = c.fg.base, bg = selection })
  set("FzfLuaCursorLineNr", { fg = c.accent.primary, bg = selection })
  set("FzfLuaSearch", { fg = c.accent.primary, bold = true })
  set("FzfLuaHeaderBind", { fg = s.keyword })
  set("FzfLuaHeaderText", { fg = c.fg.fg2 })
  set("FzfLuaPathColNr", { fg = c.fg.fg4 })
  set("FzfLuaPathLineNr", { fg = c.fg.fg4 })
  set("FzfLuaDirIcon", { fg = c.accent.primary })
  set("FzfLuaDirPart", { fg = c.fg.fg3 })
  set("FzfLuaFilePart", { fg = c.fg.base })
  set("FzfLuaBufName", { fg = c.accent.primary })
  set("FzfLuaBufId", { fg = c.fg.fg4 })
  set("FzfLuaBufNr", { fg = c.fg.fg4 })
  set("FzfLuaBufLineNr", { fg = c.fg.fg4 })
  set("FzfLuaBufFlagCur", { fg = c.states.success })
  set("FzfLuaBufFlagAlt", { fg = c.states.warn })
  set("FzfLuaTabTitle", { fg = c.fg.base, bold = true })
  set("FzfLuaTabMarker", { fg = c.states.success })
  set("FzfLuaLivePrompt", { fg = c.accent.primary })
  set("FzfLuaLiveSym", { fg = c.states.warn })
  set("FzfLuaHelpNormal", { fg = c.fg.base, bg = bg_elevated })
  set("FzfLuaHelpBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("FzfLuaBackdrop", { bg = c.bg.window })
  set("FzfLuaFzfNormal", { fg = c.fg.base, bg = bg_elevated })
  set("FzfLuaFzfBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("FzfLuaFzfCursorLine", { fg = c.fg.base, bg = selection })
  set("FzfLuaFzfMatch", { fg = c.accent.primary, bold = true })
  set("FzfLuaFzfPrompt", { fg = c.accent.primary })
  set("FzfLuaFzfQuery", { fg = c.fg.base })
  set("FzfLuaFzfPointer", { fg = c.states.warn })
  set("FzfLuaFzfMarker", { fg = c.states.success })
  set("FzfLuaFzfSpinner", { fg = c.states.warn })
  set("FzfLuaFzfInfo", { fg = c.fg.fg3 })
  set("FzfLuaFzfHeader", { fg = c.fg.fg2 })
  set("FzfLuaFzfGutter", { bg = bg_elevated })
  set("FzfLuaFzfScrollbar", { fg = c.fg.fg4 })
  set("FzfLuaFzfSeparator", { fg = c.border.elevated })
  set("FzfLuaScrollBorderEmpty", { fg = c.border.elevated })
  set("FzfLuaScrollBorderFull", { fg = c.accent.primary })
  set("FzfLuaScrollFloatEmpty", { fg = c.border.elevated })
  set("FzfLuaScrollFloatFull", { fg = c.accent.primary })

  -- LazyVim, Lazy, Mason, WhichKey, Snacks
  set("LazyNormal", { fg = c.fg.base, bg = bg_elevated })
  set("LazyBackdrop", { bg = c.bg.window })
  set("LazyButton", { fg = c.fg.fg2, bg = c.bg.inset })
  set("LazyButtonActive", { fg = c.fg.base, bg = selection })
  set("LazySpecial", { fg = c.accent.primary })
  set("LazyH1", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("LazyH2", { fg = c.accent.primary, bold = true })
  set("LazyCommit", { fg = s.string })
  set("LazyCommitIssue", { fg = s.decorator })
  set("LazyCommitScope", { fg = s.namespace })
  set("LazyCommitType", { fg = s.keyword })
  set("LazyDir", { fg = c.accent.primary })
  set("LazyUrl", { fg = c.accent.link, underline = true })
  set("LazyLocal", { fg = c.states.success })
  set("LazyNoCond", { fg = c.states.warn })
  set("LazyProp", { fg = c.fg.fg3 })
  set("LazyValue", { fg = s.string })
  set("LazyDimmed", { fg = c.fg.fg4 })
  set("LazyComment", { fg = s.comment })
  set("LazyBold", { bold = true })
  set("LazyItalic", { italic = true })
  set("LazyReasonCmd", { fg = s.func })
  set("LazyReasonEvent", { fg = s.keyword })
  set("LazyReasonFt", { fg = s.type })
  set("LazyReasonImport", { fg = s.namespace })
  set("LazyReasonKeys", { fg = s.decorator })
  set("LazyReasonPlugin", { fg = c.accent.primary })
  set("LazyReasonRequire", { fg = s.constant })
  set("LazyReasonRuntime", { fg = s.operator })
  set("LazyReasonSource", { fg = s.string })
  set("LazyReasonStart", { fg = c.states.success })
  set("LazyProgressDone", { fg = c.accent.primary })
  set("LazyProgressTodo", { fg = c.border.indentGuide })
  set("LazyTaskOutput", { fg = c.fg.fg2 })
  set("LazyError", { fg = c.states.danger })
  set("LazyWarning", { fg = c.states.warn })
  set("LazyInfo", { fg = c.states.info })
  set("MasonNormal", { fg = c.fg.base, bg = bg_elevated })
  set("MasonHeader", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("MasonHeaderSecondary", { fg = c.bg.editor, bg = c.states.success, bold = true })
  set("MasonHeading", { fg = c.fg.base, bold = true })
  set("MasonHighlight", { fg = c.accent.primary })
  set("MasonHighlightSecondary", { fg = c.states.success })
  set("MasonHighlightBlock", { fg = c.accent.contrast, bg = c.accent.primary })
  set("MasonHighlightBlockBold", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("MasonHighlightBlockSecondary", { fg = c.bg.editor, bg = c.states.success })
  set("MasonHighlightBlockBoldSecondary", { fg = c.bg.editor, bg = c.states.success, bold = true })
  set("MasonMuted", { fg = c.fg.fg3 })
  set("MasonMutedBlock", { fg = c.fg.fg2, bg = c.bg.inset })
  set("MasonMutedBlockBold", { fg = c.fg.fg2, bg = c.bg.inset, bold = true })
  set("MasonError", { fg = c.states.danger })
  set("MasonWarning", { fg = c.states.warn })
  set("MasonLink", { fg = c.accent.link, underline = true })
  set("WhichKey", { fg = c.accent.primary })
  set("WhichKeyDesc", { fg = c.fg.base })
  set("WhichKeyGroup", { fg = s.keyword })
  set("WhichKeySeparator", { fg = c.fg.fg4 })
  set("WhichKeyValue", { fg = c.fg.fg3 })
  set("WhichKeyNormal", { fg = c.fg.base, bg = bg_elevated })
  set("WhichKeyBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("WhichKeyTitle", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("WhichKeyIcon", { fg = c.accent.primary })
  set("WhichKeyIconAzure", { fg = c.states.info })
  set("WhichKeyIconBlue", { fg = c.accent.primary })
  set("WhichKeyIconCyan", { fg = s.operator })
  set("WhichKeyIconGreen", { fg = c.states.success })
  set("WhichKeyIconGrey", { fg = c.fg.fg3 })
  set("WhichKeyIconOrange", { fg = s.parameter })
  set("WhichKeyIconPurple", { fg = s.type })
  set("WhichKeyIconRed", { fg = c.states.danger })
  set("WhichKeyIconYellow", { fg = c.states.warn })
  link("WhichKeyColorAzure", "WhichKeyIconAzure")
  link("WhichKeyColorBlue", "WhichKeyIconBlue")
  link("WhichKeyColorCyan", "WhichKeyIconCyan")
  link("WhichKeyColorGreen", "WhichKeyIconGreen")
  link("WhichKeyColorGrey", "WhichKeyIconGrey")
  link("WhichKeyColorOrange", "WhichKeyIconOrange")
  link("WhichKeyColorPurple", "WhichKeyIconPurple")
  link("WhichKeyColorRed", "WhichKeyIconRed")
  link("WhichKeyColorYellow", "WhichKeyIconYellow")
  set("SnacksNormal", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksNormalNC", { fg = c.fg.fg2, bg = bg_elevated })
  set("SnacksWinBar", { fg = c.fg.base, bg = bg_elevated, bold = true })
  set("SnacksWinBarNC", { fg = c.fg.fg3, bg = bg_elevated })
  set("SnacksWinSeparator", { fg = c.border.elevated, bg = bg_elevated })
  set("SnacksTitle", { fg = c.accent.contrast, bg = c.accent.primary, bold = true })
  set("SnacksFooter", { fg = c.fg.fg3, bg = bg_elevated })
  set("SnacksFooterKey", { fg = c.states.warn, bg = bg_elevated })
  set("SnacksFooterDesc", { fg = c.fg.fg2, bg = bg_elevated })
  set("SnacksWinKey", { fg = c.states.warn })
  set("SnacksWinKeyDesc", { fg = c.fg.fg2 })
  set("SnacksWinKeySep", { fg = c.fg.fg4 })
  set("SnacksInput", { fg = c.fg.base, bg = c.bg.inset })
  set("SnacksInputNormal", { fg = c.fg.base, bg = c.bg.inset })
  set("SnacksInputBorder", { fg = c.border.inset, bg = c.bg.inset })
  set("SnacksInputTitle", { fg = c.accent.primary, bg = c.bg.inset, bold = true })
  set("SnacksInputIcon", { fg = c.accent.primary, bg = c.bg.inset })
  set("SnacksPicker", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksPickerBox", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksPickerBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("SnacksPickerInput", { fg = c.fg.base, bg = c.bg.inset })
  set("SnacksPickerInputSearch", { fg = c.states.warn, bg = c.bg.inset })
  set("SnacksPickerList", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksPickerPreview", { fg = c.fg.base, bg = bg_editor })
  set("SnacksPickerListCursorLine", { fg = c.fg.base, bg = selection })
  set("SnacksPickerPreviewCursorLine", { bg = cursorline })
  set("SnacksPickerPrompt", { fg = c.accent.primary })
  set("SnacksPickerMatch", { fg = c.accent.primary, bold = true })
  set("SnacksPickerSelected", { fg = c.states.success })
  set("SnacksPickerUnselected", { fg = c.fg.fg4 })
  set("SnacksPickerBold", { fg = c.fg.base, bold = true })
  set("SnacksPickerItalic", { fg = c.fg.fg2, italic = true })
  set("SnacksPickerDimmed", { fg = c.fg.fg4 })
  set("SnacksPickerComment", { fg = s.comment })
  set("SnacksPickerDelim", { fg = s.punctuation })
  set("SnacksPickerDesc", { fg = c.fg.fg2 })
  set("SnacksPickerDir", { fg = c.fg.fg3 })
  set("SnacksPickerDirectory", { fg = c.fg.fg3 })
  set("SnacksPickerFile", { fg = c.fg.base })
  set("SnacksPickerFileType", { fg = s.type })
  set("SnacksPickerIcon", { fg = c.accent.primary })
  set("SnacksPickerIconCategory", { fg = s.namespace })
  set("SnacksPickerIconName", { fg = s.type })
  set("SnacksPickerIconSource", { fg = c.fg.fg3 })
  set("SnacksPickerIdx", { fg = c.fg.fg4 })
  set("SnacksPickerKeymapLhs", { fg = c.states.warn })
  set("SnacksPickerKeymapMode", { fg = s.keyword })
  set("SnacksPickerKeymapRhs", { fg = c.fg.fg3 })
  set("SnacksPickerLabel", { fg = s.attribute })
  set("SnacksPickerLink", { fg = c.accent.link, underline = true })
  set("SnacksPickerLinkBroken", { fg = c.states.danger, underline = true })
  set("SnacksPickerPathHidden", { fg = c.fg.fg4 })
  set("SnacksPickerPathIgnored", { fg = c.fg.fg4 })
  set("SnacksPickerPickWin", { fg = c.bg.editor, bg = c.states.warn, bold = true })
  set("SnacksPickerRegister", { fg = s.constant })
  set("SnacksPickerRow", { fg = c.fg.fg3 })
  set("SnacksPickerSearch", { fg = c.states.warn })
  set("SnacksPickerSpecial", { fg = s.decorator })
  set("SnacksPickerSpinner", { fg = c.states.warn })
  set("SnacksPickerToggle", { fg = c.states.success })
  set("SnacksPickerTotals", { fg = c.fg.fg3 })
  set("SnacksPickerTree", { fg = c.border.indentGuide })
  set("SnacksPickerGit", { fg = c.fg.fg3 })
  set("SnacksPickerGitAuthor", { fg = s.namespace })
  set("SnacksPickerGitBranch", { fg = c.accent.primary })
  set("SnacksPickerGitBranchCurrent", { fg = c.states.success })
  set("SnacksPickerGitCommit", { fg = s.string })
  set("SnacksPickerGitDate", { fg = c.fg.fg4 })
  set("SnacksPickerGitDetached", { fg = c.states.warn })
  set("SnacksPickerGitIssue", { fg = s.decorator })
  set("SnacksPickerGitMsg", { fg = c.fg.fg2 })
  set("SnacksPickerGitScope", { fg = s.namespace })
  set("SnacksPickerGitStatus", { fg = c.fg.fg3 })
  set("SnacksPickerGitStatusAdded", { fg = c.states.success })
  set("SnacksPickerGitStatusCopied", { fg = c.states.success })
  set("SnacksPickerGitStatusDeleted", { fg = c.states.danger })
  set("SnacksPickerGitStatusModified", { fg = c.accent.primary })
  set("SnacksPickerGitStatusRenamed", { fg = c.states.warn })
  set("SnacksPickerGitStatusStaged", { fg = c.states.success })
  set("SnacksPickerGitStatusUnmerged", { fg = c.states.merge })
  set("SnacksPickerGitStatusUntracked", { fg = c.states.success })
  set("SnacksPickerUndoAdded", { fg = c.states.success })
  set("SnacksPickerUndoRemoved", { fg = c.states.danger })
  set("SnacksPickerUndoSaved", { fg = c.accent.primary })
  set("SnacksPickerUndoCurrent", { fg = c.states.warn })
  set("SnacksDashboardHeader", { fg = c.accent.primary })
  set("SnacksDashboardKey", { fg = s.keyword })
  set("SnacksDashboardDesc", { fg = c.fg.base })
  set("SnacksDashboardIcon", { fg = s.decorator })
  set("SnacksDashboardNormal", { fg = c.fg.base, bg = bg_editor })
  set("SnacksDashboardTerminal", { fg = c.fg.fg2, bg = bg_editor })
  set("SnacksNotifier", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksNotifierMinimal", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksNotifierHistory", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksNotifierHistoryTitle", { fg = c.accent.primary, bold = true })
  set("SnacksScratch", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksScratchTitle", { fg = c.accent.primary, bold = true })
  set("SnacksProfiler", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksProfilerIcon", { fg = c.accent.primary })
  set("SnacksProfilerBadge", { fg = c.bg.editor, bg = c.accent.primary })
  set("SnacksProfilerBadgeInfo", { fg = c.bg.editor, bg = c.states.info })
  set("SnacksProfilerBadgeTrace", { fg = c.bg.editor, bg = c.states.warn })
  set("SnacksProfilerHot", { fg = c.states.danger })
  set("SnacksProfilerLoaded", { fg = c.states.success })
  set("SnacksProfilerStarted", { fg = c.states.success })
  set("SnacksProfilerStopped", { fg = c.states.danger })
  set("SnacksZen", { fg = c.fg.base, bg = bg_editor })
  set("SnacksZenIcon", { fg = c.accent.primary })
  set("SnacksStatusColumn", { fg = c.fg.fg3, bg = bg_editor })
  set("SnacksStatusColumnMark", { fg = c.states.warn, bg = bg_editor })
  set("SnacksDiffAdd", { fg = c.states.success, bg = diff_add })
  set("SnacksDiffDelete", { fg = c.states.danger, bg = diff_delete })
  set("SnacksDiffChange", { fg = c.accent.primary, bg = diff_change })
  set("SnacksDiffConflict", { fg = c.states.merge })
  set("SnacksDiffContext", { fg = c.fg.fg3 })
  set("SnacksDiffHeader", { fg = c.fg.base, bold = true })
  set("SnacksDiffLabel", { fg = c.bg.editor, bg = c.accent.primary })
  set("SnacksGhNormal", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksGhNormalFloat", { fg = c.fg.base, bg = bg_elevated })
  set("SnacksGhBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("SnacksGhTitle", { fg = c.accent.primary, bold = true })
  set("SnacksGhFooter", { fg = c.fg.fg3 })
  set("SnacksGhBranch", { fg = c.accent.primary })
  set("SnacksGhAdditions", { fg = c.states.success })
  set("SnacksGhDeletions", { fg = c.states.danger })
  set("SnacksGhPrClean", { fg = c.states.success })
  set("SnacksGhPrDirty", { fg = c.states.warn })
  set("SnacksGhGray", { fg = c.fg.fg3 })
  set("SnacksGhGreen", { fg = c.states.success })
  set("SnacksGhRed", { fg = c.states.danger })
  set("SnacksGhPurple", { fg = s.type })
  set("SnacksGhUserBadge", { fg = c.bg.editor, bg = c.accent.primary })
  set("SnacksGhBotBadge", { fg = c.bg.editor, bg = c.states.warn })
  set("SnacksGhOwnerBadge", { fg = c.bg.editor, bg = c.states.success })
  set("SnacksGhReactionBadge", { fg = c.fg.base, bg = c.bg.inset })
  set("SnacksGhSuggestionBadge", { fg = c.bg.editor, bg = s.type })
  set("SnacksGhScratchBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("SnacksGhScratchTitle", { fg = c.accent.primary, bg = bg_elevated, bold = true })

  -- Noice
  set("NoiceCmdlinePopup", { fg = c.fg.base, bg = bg_elevated })
  set("NoiceCmdlinePopupBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderSearch", { fg = c.states.warn, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderInput", { fg = c.accent.primary, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderCmdline", { fg = c.accent.primary, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderLua", { fg = s.decorator, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderHelp", { fg = c.states.success, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderFilter", { fg = s.keyword, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderCalculator", { fg = s.operator, bg = bg_elevated })
  set("NoiceCmdlinePopupBorderIncRename", { fg = c.states.warn, bg = bg_elevated })
  set("NoiceCmdlinePopupTitle", { fg = c.fg.base, bg = bg_elevated })
  set("NoiceCmdlineIcon", { fg = c.accent.primary, bg = bg_elevated })
  set("NoiceCmdlineIconSearch", { fg = c.states.warn, bg = bg_elevated })
  set("NoiceCmdlineIconCmdline", { fg = c.accent.primary, bg = bg_elevated })
  set("NoiceCmdlineIconLua", { fg = s.decorator, bg = bg_elevated })
  set("NoiceCmdlineIconHelp", { fg = c.states.success, bg = bg_elevated })
  set("NoiceCmdlineIconFilter", { fg = s.keyword, bg = bg_elevated })
  set("NoiceCmdlineIconCalculator", { fg = s.operator, bg = bg_elevated })
  set("NoiceCmdlineIconIncRename", { fg = c.states.warn, bg = bg_elevated })
  set("NoiceCmdlinePrompt", { fg = c.accent.primary })
  set("NoiceConfirmBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("NoicePopup", { fg = c.fg.base, bg = bg_elevated })
  set("NoicePopupBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("NoicePopupmenu", { fg = c.fg.base, bg = bg_elevated })
  set("NoicePopupmenuBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("NoicePopupmenuSelected", { fg = c.fg.base, bg = selection })
  set("NoicePopupmenuMatch", { fg = c.accent.primary, bold = true })
  set("NoicePopupmenuItemKind", { fg = s.type })
  set("NoiceSplit", { fg = c.fg.base, bg = bg_editor })
  set("NoiceSplitBorder", { fg = c.border.window, bg = bg_editor })
  set("NoiceVirtualText", { fg = c.fg.fg3 })
  set("NoiceMini", { fg = c.fg.fg2, bg = bg_elevated })
  set("NoiceFormatProgressDone", { fg = c.accent.primary, bg = c.accent.primary })
  set("NoiceFormatProgressTodo", { fg = c.border.indentGuide, bg = c.border.indentGuide })
  set("NoiceFormatLevelDebug", { fg = c.fg.fg3 })
  set("NoiceFormatLevelTrace", { fg = c.fg.fg4 })
  set("NoiceFormatLevelInfo", { fg = c.states.info })
  set("NoiceFormatLevelWarn", { fg = c.states.warn })
  set("NoiceFormatLevelError", { fg = c.states.danger })
  set("NoiceLspProgressTitle", { fg = c.fg.base })
  set("NoiceLspProgressClient", { fg = c.fg.fg3 })
  set("NoiceLspProgressSpinner", { fg = c.states.warn })
  set("NoiceScrollbar", { fg = c.border.elevated })
  set("NoiceScrollbarThumb", { fg = c.fg.fg4 })
  link("NoiceCompletionItemKindDefault", "CmpItemKind")
  link("NoiceCompletionItemKindClass", "CmpItemKindClass")
  link("NoiceCompletionItemKindColor", "CmpItemKindConstant")
  link("NoiceCompletionItemKindConstant", "CmpItemKindConstant")
  link("NoiceCompletionItemKindConstructor", "CmpItemKindConstructor")
  link("NoiceCompletionItemKindEnum", "CmpItemKindEnum")
  link("NoiceCompletionItemKindEnumMember", "CmpItemKindEnumMember")
  link("NoiceCompletionItemKindField", "CmpItemKindField")
  link("NoiceCompletionItemKindFile", "Directory")
  link("NoiceCompletionItemKindFolder", "Directory")
  link("NoiceCompletionItemKindFunction", "CmpItemKindFunction")
  link("NoiceCompletionItemKindInterface", "CmpItemKindInterface")
  link("NoiceCompletionItemKindKeyword", "CmpItemKindKeyword")
  link("NoiceCompletionItemKindMethod", "CmpItemKindMethod")
  link("NoiceCompletionItemKindModule", "CmpItemKindModule")
  link("NoiceCompletionItemKindProperty", "CmpItemKindProperty")
  link("NoiceCompletionItemKindSnippet", "CmpItemKindSnippet")
  link("NoiceCompletionItemKindStruct", "CmpItemKindClass")
  link("NoiceCompletionItemKindText", "Normal")
  link("NoiceCompletionItemKindUnit", "CmpItemKindNumber")
  link("NoiceCompletionItemKindValue", "CmpItemKindConstant")
  link("NoiceCompletionItemKindVariable", "CmpItemKindVariable")

  -- File tree plugins
  set("NeoTreeNormal", { fg = c.fg.base, bg = bg_editor })
  set("NeoTreeNormalNC", { fg = c.fg.base, bg = bg_editor })
  set("NeoTreeSignColumn", { bg = bg_editor })
  set("NeoTreeEndOfBuffer", { fg = c.bg.window, bg = bg_editor })
  set("NeoTreeWinSeparator", { fg = c.border.window, bg = bg_editor })
  set("NeoTreeCursorLine", { bg = hover })
  set("NeoTreeRootName", { fg = c.fg.base, bold = true })
  set("NeoTreeDirectoryIcon", { fg = c.accent.primary })
  set("NeoTreeDirectoryName", { fg = c.accent.primary })
  set("NeoTreeFileName", { fg = c.fg.fg2 })
  set("NeoTreeFileNameOpened", { fg = c.fg.base, bold = true })
  set("NeoTreeIndentMarker", { fg = c.border.indentGuide })
  set("NeoTreeExpander", { fg = c.fg.fg4 })
  set("NeoTreeDimText", { fg = c.fg.fg4 })
  set("NeoTreeModified", { fg = c.states.warn })
  set("NeoTreeGitAdded", { fg = c.states.success })
  set("NeoTreeGitDeleted", { fg = c.states.danger })
  set("NeoTreeGitModified", { fg = c.accent.primary })
  set("NeoTreeGitRenamed", { fg = c.states.warn })
  set("NeoTreeGitStaged", { fg = c.states.success })
  set("NeoTreeGitUnstaged", { fg = c.states.warn })
  set("NeoTreeGitUntracked", { fg = c.states.success })
  set("NeoTreeGitIgnored", { fg = c.fg.fg4 })
  set("NeoTreeGitConflict", { fg = c.states.merge })
  set("NeoTreeBufferNumber", { fg = c.fg.fg4 })
  set("NeoTreeDotfile", { fg = c.fg.fg4 })
  set("NeoTreeFileIcon", { fg = c.fg.fg2 })
  set("NeoTreeFileStats", { fg = c.fg.fg4 })
  set("NeoTreeFileStatsHeader", { fg = c.fg.fg3, bold = true })
  set("NeoTreeFilterTerm", { fg = c.states.warn })
  set("NeoTreeFloatNormal", { fg = c.fg.base, bg = bg_editor })
  set("NeoTreeFloatBorder", { fg = c.border.elevated, bg = bg_editor })
  set("NeoTreeFloatTitle", { fg = c.accent.primary, bg = bg_editor, bold = true })
  set("NeoTreeHiddenByName", { fg = c.fg.fg4 })
  set("NeoTreeIgnored", { fg = c.fg.fg4 })
  set("NeoTreeMessage", { fg = c.fg.fg3 })
  set("NeoTreePreview", { fg = c.bg.editor, bg = c.accent.primary })
  set("NeoTreeSelected", { fg = c.fg.base, bg = hover })
  set("NeoTreeStats", { fg = c.fg.fg4 })
  set("NeoTreeStatsHeader", { fg = c.fg.fg3, bold = true })
  set("NeoTreeSymbolicLinkTarget", { fg = c.accent.link })
  set("NeoTreeTabActive", { fg = c.fg.base, bg = bg_window, bold = true })
  set("NeoTreeTabInactive", { fg = c.fg.fg3, bg = bg_window })
  set("NeoTreeTabSeparatorActive", { fg = c.border.window, bg = bg_editor })
  set("NeoTreeTabSeparatorInactive", { fg = c.border.window, bg = bg_editor })
  set("NeoTreeTitleBar", { fg = c.accent.primary, bg = bg_editor, bold = true })
  set("NeoTreeVertSplit", { fg = c.border.window, bg = bg_editor })
  set("NeoTreeStatusLine", { fg = c.fg.fg2, bg = bg_editor })
  set("NeoTreeStatusLineNC", { fg = c.fg.fg3, bg = bg_editor })
  set("NeoTreeWindowsHidden", { fg = c.fg.fg4 })
  set("NvimTreeNormal", { fg = c.fg.base, bg = bg_editor })
  set("NvimTreeNormalNC", { fg = c.fg.base, bg = bg_editor })
  set("NvimTreeCursorLine", { bg = selection })
  set("NvimTreeFolderName", { fg = c.accent.primary })
  set("NvimTreeFolderIcon", { fg = c.accent.primary })
  set("NvimTreeOpenedFolderName", { fg = c.accent.primary, bold = true })
  set("NvimTreeRootFolder", { fg = c.fg.base, bold = true })
  set("NvimTreeSpecialFile", { fg = c.states.warn })
  set("NvimTreeImageFile", { fg = s.type })
  set("NvimTreeSymlink", { fg = c.accent.link })
  set("NvimTreeGitDirty", { fg = c.accent.primary })
  set("NvimTreeGitNew", { fg = c.states.success })
  set("NvimTreeGitDeleted", { fg = c.states.danger })
  set("NvimTreeGitStaged", { fg = c.states.success })
  set("NvimTreeGitMerge", { fg = c.states.merge })
  set("NvimTreeGitRenamed", { fg = c.states.warn })
  set("NvimTreeGitIgnored", { fg = c.fg.fg4 })

  -- Git and trouble-style lists
  set("GitSignsAdd", { fg = c.states.success, bg = bg_editor })
  set("GitSignsChange", { fg = c.accent.primary, bg = bg_editor })
  set("GitSignsDelete", { fg = c.states.danger, bg = bg_editor })
  set("GitSignsTopdelete", { fg = c.states.danger, bg = bg_editor })
  set("GitSignsChangedelete", { fg = c.states.warn, bg = bg_editor })
  set("GitSignsUntracked", { fg = c.states.success, bg = bg_editor })
  set("GitSignsAddNr", { fg = c.states.success, bg = bg_editor })
  set("GitSignsChangeNr", { fg = c.accent.primary, bg = bg_editor })
  set("GitSignsDeleteNr", { fg = c.states.danger, bg = bg_editor })
  set("GitSignsTopdeleteNr", { fg = c.states.danger, bg = bg_editor })
  set("GitSignsChangedeleteNr", { fg = c.states.warn, bg = bg_editor })
  set("GitSignsUntrackedNr", { fg = c.states.success, bg = bg_editor })
  set("GitSignsAddCul", { fg = c.states.success, bg = cursorline })
  set("GitSignsChangeCul", { fg = c.accent.primary, bg = cursorline })
  set("GitSignsDeleteCul", { fg = c.states.danger, bg = cursorline })
  set("GitSignsAddLn", { bg = diff_add })
  set("GitSignsChangeLn", { bg = diff_change })
  set("GitSignsDeleteLn", { bg = diff_delete })
  set("GitSignsTopdeleteLn", { bg = diff_delete })
  set("GitSignsChangedeleteLn", { bg = diff_change })
  set("GitSignsUntrackedLn", { bg = diff_add })
  set("GitSignsAddInline", { bg = diff_add })
  set("GitSignsChangeInline", { bg = diff_text })
  set("GitSignsDeleteInline", { bg = diff_delete })
  set("GitSignsAddLnInline", { bg = diff_add })
  set("GitSignsChangeLnInline", { bg = diff_text })
  set("GitSignsDeleteLnInline", { bg = diff_delete })
  set("GitSignsCurrentLineBlame", { fg = c.fg.fg4, italic = true })
  set("GitSignsAddPreview", { fg = c.states.success })
  set("GitSignsDeletePreview", { fg = c.states.danger })
  set("GitSignsStagedAdd", { fg = blend(c.states.success, c.fg.fg3, 0.60), bg = bg_editor })
  set("GitSignsStagedChange", { fg = blend(c.accent.primary, c.fg.fg3, 0.60), bg = bg_editor })
  set("GitSignsStagedDelete", { fg = blend(c.states.danger, c.fg.fg3, 0.60), bg = bg_editor })
  set("GitSignsStagedTopdelete", { fg = blend(c.states.danger, c.fg.fg3, 0.60), bg = bg_editor })
  set("GitSignsStagedChangedelete", { fg = blend(c.states.warn, c.fg.fg3, 0.60), bg = bg_editor })
  set("GitSignsStagedUntracked", { fg = blend(c.states.success, c.fg.fg3, 0.60), bg = bg_editor })
  set("TroubleNormal", { fg = c.fg.base, bg = bg_editor })
  set("TroubleNormalNC", { fg = c.fg.base, bg = bg_editor })
  set("TroubleCount", { fg = c.accent.primary, bg = selection })
  set("TroubleText", { fg = c.fg.fg2 })
  set("TroubleIndent", { fg = c.border.indentGuide })
  set("TroubleIndentFoldClosed", { fg = c.fg.fg4 })
  set("TroubleIndentFoldOpen", { fg = c.fg.fg4 })
  set("TroubleIndentLast", { fg = c.border.indentGuide })
  set("TroubleIndentMiddle", { fg = c.border.indentGuide })
  set("TroubleIndentTop", { fg = c.border.indentGuide })
  set("TroubleIndentWs", { fg = c.border.indentGuide })
  set("TroubleBasename", { fg = c.fg.base, bold = true })
  set("TroubleDirectory", { fg = c.fg.fg3 })
  set("TroubleFilename", { fg = c.fg.base })
  set("TroubleSource", { fg = c.fg.fg4 })
  set("TroubleCode", { fg = s.constant })
  set("TroublePos", { fg = c.fg.fg4 })
  set("TroublePreview", { bg = selection })
  set("TroubleStatusline", { fg = c.fg.fg2, bg = bg_window })
  set("TroubleIconDirectory", { fg = c.accent.primary })
  set("TroubleIconFile", { fg = c.fg.fg2 })
  set("TroubleIconArray", { fg = s.type })
  set("TroubleIconBoolean", { fg = s.number })
  set("TroubleIconClass", { fg = s.type })
  set("TroubleIconConstant", { fg = s.constant })
  set("TroubleIconConstructor", { fg = s.type })
  set("TroubleIconEnum", { fg = s.type })
  set("TroubleIconEnumMember", { fg = s.operator })
  set("TroubleIconEvent", { fg = s.decorator })
  set("TroubleIconField", { fg = s.property })
  set("TroubleIconFunction", { fg = s.func })
  set("TroubleIconInterface", { fg = s.type })
  set("TroubleIconKey", { fg = s.constant })
  set("TroubleIconMethod", { fg = s.func })
  set("TroubleIconModule", { fg = s.namespace })
  set("TroubleIconNamespace", { fg = s.namespace })
  set("TroubleIconNull", { fg = c.fg.fg4 })
  set("TroubleIconNumber", { fg = s.number })
  set("TroubleIconObject", { fg = s.type })
  set("TroubleIconOperator", { fg = s.operator })
  set("TroubleIconPackage", { fg = s.namespace })
  set("TroubleIconProperty", { fg = s.property })
  set("TroubleIconString", { fg = s.string })
  set("TroubleIconStruct", { fg = s.type })
  set("TroubleIconTypeParameter", { fg = s.type })
  set("TroubleIconVariable", { fg = s.variable })

  -- Bufferline
  set("BufferLineFill", { bg = bg_window })
  set("BufferLineBackground", { fg = c.fg.fg3, bg = bg_window })
  set("BufferLineBufferVisible", { fg = c.fg.fg2, bg = bg_window })
  set("BufferLineBufferSelected", { fg = c.fg.base, bg = bg_editor, bold = true })
  set("BufferLineTab", { fg = c.fg.fg3, bg = bg_window })
  set("BufferLineTabSelected", { fg = c.fg.base, bg = bg_editor, bold = true })
  set("BufferLineTabClose", { fg = c.states.danger, bg = bg_window })
  set("BufferLineCloseButton", { fg = c.fg.fg4, bg = bg_window })
  set("BufferLineCloseButtonVisible", { fg = c.fg.fg3, bg = bg_window })
  set("BufferLineCloseButtonSelected", { fg = c.states.danger, bg = bg_editor })
  set("BufferLineIndicatorSelected", { fg = c.accent.primary, bg = bg_editor })
  set("BufferLineIndicatorVisible", { fg = c.border.window, bg = bg_window })
  set("BufferLineSeparator", { fg = c.border.window, bg = bg_window })
  set("BufferLineSeparatorVisible", { fg = c.border.window, bg = bg_window })
  set("BufferLineSeparatorSelected", { fg = c.border.window, bg = bg_editor })
  set("BufferLineNumbers", { fg = c.fg.fg4, bg = bg_window })
  set("BufferLineNumbersVisible", { fg = c.fg.fg3, bg = bg_window })
  set("BufferLineNumbersSelected", { fg = c.fg.fg2, bg = bg_editor, bold = true })
  set("BufferLineModified", { fg = c.states.warn, bg = bg_window })
  set("BufferLineModifiedVisible", { fg = c.states.warn, bg = bg_window })
  set("BufferLineModifiedSelected", { fg = c.states.warn, bg = bg_editor })
  set("BufferLineDuplicate", { fg = c.fg.fg4, bg = bg_window, italic = true })
  set("BufferLineDuplicateVisible", { fg = c.fg.fg4, bg = bg_window, italic = true })
  set("BufferLineDuplicateSelected", { fg = c.fg.fg3, bg = bg_editor, italic = true })
  set("BufferLinePick", { fg = c.states.warn, bg = bg_window, bold = true })
  set("BufferLinePickVisible", { fg = c.states.warn, bg = bg_window, bold = true })
  set("BufferLinePickSelected", { fg = c.states.warn, bg = bg_editor, bold = true })
  set("BufferLineDiagnostic", { fg = c.fg.fg4, bg = bg_window })
  set("BufferLineDiagnosticVisible", { fg = c.fg.fg3, bg = bg_window })
  set("BufferLineDiagnosticSelected", { fg = c.fg.fg2, bg = bg_editor })
  set("BufferLineHint", { fg = c.accent.primary, bg = bg_window })
  set("BufferLineHintVisible", { fg = c.accent.primary, bg = bg_window })
  set("BufferLineHintSelected", { fg = c.accent.primary, bg = bg_editor })
  set("BufferLineHintDiagnostic", { fg = c.accent.primary, bg = bg_window })
  set("BufferLineHintDiagnosticVisible", { fg = c.accent.primary, bg = bg_window })
  set("BufferLineHintDiagnosticSelected", { fg = c.accent.primary, bg = bg_editor })
  set("BufferLineInfo", { fg = c.states.info, bg = bg_window })
  set("BufferLineInfoVisible", { fg = c.states.info, bg = bg_window })
  set("BufferLineInfoSelected", { fg = c.states.info, bg = bg_editor })
  set("BufferLineInfoDiagnostic", { fg = c.states.info, bg = bg_window })
  set("BufferLineInfoDiagnosticVisible", { fg = c.states.info, bg = bg_window })
  set("BufferLineInfoDiagnosticSelected", { fg = c.states.info, bg = bg_editor })
  set("BufferLineWarning", { fg = c.states.warn, bg = bg_window })
  set("BufferLineWarningVisible", { fg = c.states.warn, bg = bg_window })
  set("BufferLineWarningSelected", { fg = c.states.warn, bg = bg_editor })
  set("BufferLineWarningDiagnostic", { fg = c.states.warn, bg = bg_window })
  set("BufferLineWarningDiagnosticVisible", { fg = c.states.warn, bg = bg_window })
  set("BufferLineWarningDiagnosticSelected", { fg = c.states.warn, bg = bg_editor })
  set("BufferLineError", { fg = c.states.danger, bg = bg_window })
  set("BufferLineErrorVisible", { fg = c.states.danger, bg = bg_window })
  set("BufferLineErrorSelected", { fg = c.states.danger, bg = bg_editor })
  set("BufferLineErrorDiagnostic", { fg = c.states.danger, bg = bg_window })
  set("BufferLineErrorDiagnosticVisible", { fg = c.states.danger, bg = bg_window })
  set("BufferLineErrorDiagnosticSelected", { fg = c.states.danger, bg = bg_editor })
  set("BufferLineOffsetSeparator", { fg = c.border.window, bg = bg_window })
  set("BufferLineTruncMarker", { fg = c.fg.fg4, bg = bg_window })
  set("BufferLineGroupLabel", { fg = c.fg.base, bg = opts.transparent and "NONE" or c.bg.inset })
  set("BufferLineGroupSeparator", { fg = c.border.window, bg = bg_window })

  -- Misc plugin groups
  set("MiniFilesNormal", { fg = c.fg.base, bg = bg_elevated })
  set("MiniFilesBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("MiniFilesTitle", { fg = c.fg.fg2, bg = bg_elevated })
  set("MiniFilesTitleFocused", { fg = c.accent.primary, bg = bg_elevated, bold = true })
  set("MiniFilesCursorLine", { bg = selection })
  set("MiniFilesDirectory", { fg = c.accent.primary })
  set("MiniFilesFile", { fg = c.fg.base })
  set("MiniFilesBorderModified", { fg = c.states.warn, bg = bg_elevated })
  set("MiniFilesActionCopy", { fg = c.states.success })
  set("MiniFilesActionCreate", { fg = c.states.success })
  set("MiniFilesActionDelete", { fg = c.states.danger })
  set("MiniFilesActionMove", { fg = c.states.warn })
  set("MiniFilesActionRename", { fg = c.states.warn })
  set("MiniSurroundHighlight", { bg = visual })
  set("YaziFloat", { fg = c.fg.base, bg = bg_elevated })
  set("YaziFloatBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("YaziBufferHovered", { bg = selection })
  set("YaziBufferHoveredInSameDirectory", { bg = hover })
  set("FlashMatch", { fg = c.fg.base, bg = search })
  set("FlashCurrent", { fg = c.bg.editor, bg = c.states.warn, bold = true })
  set("FlashLabel", { fg = c.bg.editor, bg = s.keyword, bold = true })
  set("FlashBackdrop", { fg = c.fg.fg4 })
  set("FlashPrompt", { fg = c.fg.base, bg = bg_elevated })
  set("FlashPromptIcon", { fg = c.states.warn, bg = bg_elevated })
  set("FlashCursor", { reverse = true })
  set("LspReferenceRead", { bg = hover })
  set("LspReferenceText", { bg = hover })
  set("LspReferenceWrite", { bg = hover })

  -- render-markdown.nvim
  set("RenderMarkdownH1", { fg = c.accent.primary, bold = true })
  set("RenderMarkdownH2", { fg = s.type, bold = true })
  set("RenderMarkdownH3", { fg = s.keyword, bold = true })
  set("RenderMarkdownH4", { fg = s.parameter, bold = true })
  set("RenderMarkdownH5", { fg = s.constant, bold = true })
  set("RenderMarkdownH6", { fg = s.string, bold = true })
  set("RenderMarkdownH1Bg", { bg = blend(c.accent.primary, c.bg.editor, 0.16) })
  set("RenderMarkdownH2Bg", { bg = blend(s.type, c.bg.editor, 0.16) })
  set("RenderMarkdownH3Bg", { bg = blend(s.keyword, c.bg.editor, 0.16) })
  set("RenderMarkdownH4Bg", { bg = blend(s.parameter, c.bg.editor, 0.16) })
  set("RenderMarkdownH5Bg", { bg = blend(s.constant, c.bg.editor, 0.16) })
  set("RenderMarkdownH6Bg", { bg = blend(s.string, c.bg.editor, 0.16) })
  set("RenderMarkdownCode", { bg = c.bg.window })
  set("RenderMarkdownCodeBorder", { fg = c.border.editor, bg = c.bg.window })
  set("RenderMarkdownCodeFallback", { fg = c.fg.fg3, bg = c.bg.window })
  set("RenderMarkdownCodeInfo", { fg = c.fg.fg3, bg = c.bg.window })
  set("RenderMarkdownCodeInline", { fg = s.string, bg = c.bg.inset })
  set("RenderMarkdownBullet", { fg = s.tag })
  set("RenderMarkdownDash", { fg = c.border.editor })
  set("RenderMarkdownTableHead", { fg = c.accent.primary, bold = true })
  set("RenderMarkdownTableRow", { fg = c.border.editor })
  set("RenderMarkdownMath", { fg = s.operator })
  set("RenderMarkdownIndent", { fg = c.border.indentGuide })
  set("RenderMarkdownQuote", { fg = c.fg.fg3 })
  set("RenderMarkdownQuote1", { fg = c.accent.primary })
  set("RenderMarkdownQuote2", { fg = s.type })
  set("RenderMarkdownQuote3", { fg = s.keyword })
  set("RenderMarkdownQuote4", { fg = s.parameter })
  set("RenderMarkdownQuote5", { fg = s.constant })
  set("RenderMarkdownQuote6", { fg = s.string })
  set("RenderMarkdownChecked", { fg = c.states.success })
  set("RenderMarkdownUnchecked", { fg = c.fg.fg4 })
  set("RenderMarkdownTodo", { fg = c.states.warn })
  set("RenderMarkdownInfo", { fg = c.states.info })
  set("RenderMarkdownSuccess", { fg = c.states.success })
  set("RenderMarkdownWarn", { fg = c.states.warn })
  set("RenderMarkdownError", { fg = c.states.danger })
  set("RenderMarkdownHint", { fg = c.accent.primary })
  set("RenderMarkdownLink", { fg = c.accent.link, underline = true })
  set("RenderMarkdownWikiLink", { fg = c.accent.link, underline = true })
  set("RenderMarkdownLinkTitle", { fg = s.func })
  set("RenderMarkdownHtmlComment", { fg = s.comment, italic = opts.italic_comments })
  set("RenderMarkdownSign", { fg = c.accent.primary })

  -- todo-comments.nvim
  local todo_colors = {
    TODO = c.accent.primary,
    FIX = c.states.danger,
    FIXME = c.states.danger,
    BUG = c.states.danger,
    FIXIT = c.states.danger,
    ISSUE = c.states.danger,
    HACK = c.states.warn,
    WARN = c.states.warn,
    WARNING = c.states.warn,
    XXX = c.states.warn,
    PERF = s.type,
    OPTIM = s.type,
    PERFORMANCE = s.type,
    OPTIMIZE = s.type,
    NOTE = c.states.info,
    INFO = c.states.info,
    TEST = c.states.success,
    TESTING = c.states.success,
    PASSED = c.states.success,
    FAILED = c.states.danger,
  }
  for name, color in pairs(todo_colors) do
    set("TodoFg" .. name, { fg = color, bold = true })
    set("TodoBg" .. name, { fg = c.bg.editor, bg = color, bold = true })
    set("TodoSign" .. name, { fg = color, bg = bg_editor })
  end

  -- nvim-dap and nvim-dap-ui
  set("DapUINormal", { fg = c.fg.base, bg = bg_window })
  set("DapUIFloatNormal", { fg = c.fg.base, bg = bg_elevated })
  set("DapUIFloatBorder", { fg = c.border.elevated, bg = bg_elevated })
  set("DapUIVariable", { fg = s.variable })
  set("DapUIScope", { fg = c.accent.primary, bold = true })
  set("DapUIType", { fg = s.type })
  set("DapUIValue", { fg = c.fg.base })
  set("DapUIModifiedValue", { fg = c.states.warn, bold = true })
  set("DapUIDecoration", { fg = c.accent.primary })
  set("DapUIThread", { fg = c.states.success })
  set("DapUIStoppedThread", { fg = c.states.warn })
  set("DapUIFrameName", { fg = c.fg.base })
  set("DapUICurrentFrameName", { fg = c.states.warn, bold = true })
  set("DapUISource", { fg = s.namespace })
  set("DapUILineNumber", { fg = c.fg.fg3 })
  set("DapUIWatchesEmpty", { fg = c.fg.fg4 })
  set("DapUIWatchesValue", { fg = c.states.success })
  set("DapUIWatchesError", { fg = c.states.danger })
  set("DapUIBreakpointsPath", { fg = c.accent.primary })
  set("DapUIBreakpointsInfo", { fg = c.states.info })
  set("DapUIBreakpointsCurrentLine", { fg = c.states.warn, bold = true })
  set("DapUIBreakpointsLine", { fg = c.fg.fg3 })
  set("DapUIBreakpointsDisabledLine", { fg = c.fg.fg4 })
  set("DapUIWinSelect", { fg = c.accent.primary, bold = true })
  set("DapUIEndOfBuffer", { fg = c.bg.window, bg = bg_window })
  link("DapUIEndofBuffer", "DapUIEndOfBuffer")
  set("DapUIPlayPause", { fg = c.states.success })
  set("DapUIRestart", { fg = c.states.success })
  set("DapUIStop", { fg = c.states.danger })
  set("DapUIUnavailable", { fg = c.fg.fg4 })
  set("DapUIStepOver", { fg = c.accent.primary })
  set("DapUIStepInto", { fg = c.accent.primary })
  set("DapUIStepBack", { fg = c.accent.primary })
  set("DapUIStepOut", { fg = c.accent.primary })
  link("DapUIPlayPauseNC", "DapUIPlayPause")
  link("DapUIRestartNC", "DapUIRestart")
  link("DapUIStopNC", "DapUIStop")
  link("DapUIUnavailableNC", "DapUIUnavailable")
  link("DapUIStepOverNC", "DapUIStepOver")
  link("DapUIStepIntoNC", "DapUIStepInto")
  link("DapUIStepBackNC", "DapUIStepBack")
  link("DapUIStepOutNC", "DapUIStepOut")
  set("NvimDapVirtualText", { fg = c.fg.fg3, italic = true })
  set("NvimDapVirtualTextChanged", { fg = c.states.warn, italic = true })
  set("NvimDapVirtualTextError", { fg = c.states.danger, italic = true })
  set("NvimDapVirtualTextInfo", { fg = c.states.info, italic = true })

  -- grug-far.nvim
  set("GrugFarHelpHeader", { fg = c.accent.primary, bold = true })
  set("GrugFarHelpHeaderKey", { fg = c.states.warn })
  set("GrugFarHelpWinHeader", { fg = c.accent.primary, bold = true })
  set("GrugFarHelpWinActionPrefix", { fg = s.keyword })
  set("GrugFarHelpWinActionText", { fg = c.fg.fg2 })
  set("GrugFarHelpWinActionKey", { fg = c.states.warn })
  set("GrugFarHelpWinActionDescription", { fg = c.fg.base, bg = bg_elevated })
  set("GrugFarInputLabel", { fg = c.accent.primary, bold = true })
  set("GrugFarInputPlaceholder", { fg = c.fg.fg4, italic = true })
  set("GrugFarResultsHeader", { fg = c.fg.fg3 })
  set("GrugFarResultsStats", { fg = c.fg.fg3 })
  set("GrugFarResultsActionMessage", { fg = c.states.info })
  set("GrugFarResultsMatch", { fg = c.fg.base, bg = diff_text })
  set("GrugFarResultsMatchAdded", { fg = c.states.success, bg = diff_add })
  set("GrugFarResultsMatchRemoved", { fg = c.states.danger, bg = diff_delete })
  set("GrugFarResultsPath", { fg = c.accent.link, underline = true })
  set("GrugFarResultsLineNr", { fg = c.fg.fg4 })
  set("GrugFarResultsCursorLineNo", { fg = c.accent.primary, bold = true })
  set("GrugFarResultsColumnNr", { fg = c.fg.fg4 })
  set("GrugFarResultsNumbersSeparator", { fg = c.fg.fg4 })
  set("GrugFarResultsChangeIndicator", { fg = c.states.warn })
  set("GrugFarResultsRemoveIndicator", { fg = c.states.danger })
  set("GrugFarResultsAddIndicator", { fg = c.states.success })
  set("GrugFarResultsDiffSeparatorIndicator", { fg = c.border.editor })
  set("GrugFarResultsCmdHeader", { fg = c.accent.link, underline = true })
  set("GrugFarResultsNumberLabel", { fg = s.constant })
  set("GrugFarResultsLongLineStr", { fg = c.fg.fg4 })
  set("GrugFarVisualBufrange", { bg = visual })

  -- crates.nvim and venv-selector.nvim
  set("None", {})
  set("CratesNvimSearching", { fg = c.states.info })
  set("CratesNvimLoading", { fg = c.states.info })
  set("CratesNvimVersion", { fg = c.states.info })
  set("CratesNvimPreRelease", { fg = c.states.warn })
  set("CratesNvimYanked", { fg = c.states.danger })
  set("CratesNvimNoMatch", { fg = c.states.danger })
  set("CratesNvimUpgrade", { fg = c.states.warn })
  set("CratesNvimError", { fg = c.states.danger })
  set("CratesNvimPopupTitle", { fg = c.accent.primary, bold = true })
  set("CratesNvimPopupPillText", { fg = c.fg.base, bg = c.bg.inset })
  set("CratesNvimPopupPillBorder", { fg = c.border.inset })
  set("CratesNvimPopupDescription", { fg = c.fg.fg3 })
  set("CratesNvimPopupLabel", { fg = s.namespace })
  set("CratesNvimPopupValue", { fg = s.string })
  set("CratesNvimPopupUrl", { fg = c.accent.link, underline = true })
  set("CratesNvimPopupVersion", { fg = c.fg.base })
  set("CratesNvimPopupPreRelease", { fg = c.states.warn })
  set("CratesNvimPopupYanked", { fg = c.states.danger })
  set("CratesNvimPopupVersionDate", { fg = c.fg.fg4 })
  set("CratesNvimPopupFeature", { fg = s.type })
  set("CratesNvimPopupEnabled", { fg = c.states.success })
  set("CratesNvimPopupTransitive", { fg = c.states.info })
  set("CratesNvimPopupNormalDependenciesTitle", { fg = s.keyword, bold = true })
  set("CratesNvimPopupBuildDependenciesTitle", { fg = s.keyword, bold = true })
  set("CratesNvimPopupDevDependenciesTitle", { fg = s.keyword, bold = true })
  set("CratesNvimPopupDependency", { fg = c.fg.base })
  set("CratesNvimPopupOptional", { fg = c.fg.fg4 })
  set("CratesNvimPopupDependencyVersion", { fg = s.string })
  set("CratesNvimPopupLoading", { fg = c.states.info })
  set("CmpItemKindVersion", { fg = c.states.info })
  set("CmpItemKindFeature", { fg = s.type })
  set("BlinkCmpKindVersion", { fg = c.states.info })
  set("BlinkCmpKindFeature", { fg = s.type })
  set("VenvSelectActiveVenv", { fg = c.states.success })
  set("VenvSelectMarker", { fg = c.states.success })
  set("VenvLogDebug", { fg = c.fg.fg3 })
  set("VenvLogInfo", { fg = c.states.info })
  set("VenvLogWarning", { fg = c.states.warn })
  set("VenvLogError", { fg = c.states.danger })
  set("VenvLogTrace", { fg = c.fg.fg4 })
  set("VenvLogTimestamp", { fg = c.fg.fg4 })

  -- Copilot, SmoothCursor, litee.nvim, gh.nvim
  set("CopilotSuggestion", { fg = c.fg.fg4, italic = true })
  set("CopilotAnnotation", { fg = c.fg.fg3 })
  set("SmoothCursor", { fg = c.states.warn })
  set("SmoothCursorRed", { fg = c.states.danger })
  set("SmoothCursorOrange", { fg = s.parameter })
  set("SmoothCursorYellow", { fg = c.states.warn })
  set("SmoothCursorGreen", { fg = c.states.success })
  set("SmoothCursorAqua", { fg = s.operator })
  set("SmoothCursorBlue", { fg = c.accent.primary })
  set("SmoothCursorPurple", { fg = s.type })
  set("LTBoolean", { fg = s.number })
  set("LTConstant", { fg = s.constant })
  set("LTConstructor", { fg = s.type })
  set("LTField", { fg = s.property })
  set("LTFunction", { fg = s.func })
  set("LTMethod", { fg = s.func })
  set("LTNamespace", { fg = s.namespace })
  set("LTNumber", { fg = s.number })
  set("LTOperator", { fg = s.operator })
  set("LTParameter", { fg = s.parameter })
  set("LTParameterReference", { fg = s.parameter })
  set("LTString", { fg = s.string })
  set("LTSymbol", { fg = c.accent.primary })
  set("LTSymbolDetail", { fg = c.fg.fg3, italic = true })
  set("LTSymbolJump", { fg = c.bg.editor, bg = c.accent.primary, bold = true })
  set("LTSymbolJumpRefs", { fg = c.bg.editor, bg = c.states.warn, bold = true })
  set("LTType", { fg = s.type })
  set("LTURI", { fg = c.accent.link, underline = true })
  set("LTIndentGuide", { fg = c.border.indentGuide })
  set("LTExpandedGuide", { fg = c.border.indentGuideActive })
  set("LTCollapsedGuide", { fg = c.border.indentGuide })
  set("LTSelectFiletree", { fg = c.fg.base, bg = selection })
  set("LTNormalSB", { fg = c.fg.base, bg = bg_window })
  link("NormalSB", "LTNormalSB")
  set("GHThreadSep", { fg = c.border.elevated, bg = bg_elevated })
  set("GHThreadSepAlt", { fg = c.border.editor, bg = bg_window })

  return c
end

function M.colors(variant)
  return (palette(variant))
end

return M
