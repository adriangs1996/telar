-- nvim --headless --clean -l integrations/nvim/tests/theme_test.lua
-- Paints the theme telar's window gives for Zenburn, as `telar pane theme` prints it, and checks
-- the editor shows the window's colors: its terminal's, and the syntax colors no ANSI color holds.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

vim.opt.rtp:prepend(root)

local failures = 0

local function check(condition, message)
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local function hex(group)
  local spec = vim.api.nvim_get_hl(0, { name = group, link = false })
  return spec.fg and string.format("#%06x", spec.fg) or nil, spec
end

local file = assert(io.open(root .. "/tests/zenburn.json"))
local zenburn = vim.json.decode(file:read("*a"))

file:close()

local theme = require("telar.theme")

check(theme.complete(zenburn), "a whole theme is complete")
check(not theme.complete({ foreground = "#000000", background = "#ffffff" }), "a theme without editor colors is not")

-- Every key tint's engine reads is in the palette.
local palette = theme.palette(zenburn)
local required = {
  bg = { "editor", "window", "inset", "elevated" },
  fg = { "base", "fg1", "fg2", "fg3", "fg4" },
  border = { "window", "editor", "indentGuide", "indentGuideActive", "inset", "elevated" },
  accent = { "primary", "link", "subtle", "contrast" },
  states = { "success", "danger", "warn", "info", "merge" },
  syntax = {
    "comment",
    "constant",
    "string",
    "number",
    "variable",
    "func",
    "interface",
    "keyword",
    "tag",
    "operator",
    "namespace",
    "type",
    "escape",
    "punctuation",
    "parameter",
    "property",
    "regexp",
    "attribute",
    "decorator",
  },
}

for section, keys in pairs(required) do
  for _, key in ipairs(keys) do
    check(type(palette[section][key]) == "string", "palette has " .. section .. "." .. key)
  end
end

check(vim.tbl_count(palette.ansi) == 16, "palette has the 16 ANSI colors")

local painted = 0

vim.api.nvim_create_autocmd("User", {
  pattern = "TelarTheme",
  callback = function()
    painted = painted + 1
  end,
})

theme.apply(zenburn, { transparent = false })
check(vim.g.colors_name == "telar", "the colorscheme is telar's")
check(painted == 1, "painting announces the theme")
check(vim.o.background == "dark", "a dark background makes a dark colorscheme")

local _, normal = hex("Normal")

check(normal.bg == 0x2b2b2b and normal.fg == 0xdcdccc, "Normal is the window's terminal colors")
check(hex("@number") == "#bfebbf", "numbers keep the color no ANSI color holds")
check(hex("@property") == "#dfaf8f", "properties keep the color no ANSI color holds")
check(hex("@constant.builtin") == zenburn.syntax.builtin_constant.color, "builtin constants take their role's color")
check(hex("@function.builtin") == zenburn.syntax.builtin.color, "builtins take their role's color")
check(vim.g.terminal_color_1 == zenburn.ansi[2], "terminal buffers get the window's ANSI colors")

local _, comment = hex("Comment")

check(not comment.italic and not comment.bold, "Zenburn styles no role")

-- A role the window styles is styled in every group it covers.
local styled = vim.deepcopy(zenburn)

styled.syntax.keyword.italic = true
styled.syntax.comment.bold = true
theme.apply(styled)

local _, keyword = hex("@keyword")
local _, statement = hex("Statement")

_, comment = hex("Comment")
check(keyword.italic and statement.italic, "italic keywords are italic in every keyword group")
check(comment.bold, "bold comments are bold")
check(hex("Normal") == "#dcdccc" and select(2, hex("Normal")).bg == nil, "transparent by default, so the window's background shows")

-- A light background makes a light colorscheme.
local light = vim.deepcopy(zenburn)

light.background = "#fafafa"
theme.apply(light)
check(vim.o.background == "light", "a light background makes a light colorscheme")

local lualine = dofile(root .. "/lua/lualine/themes/telar.lua")

check(type(lualine) == "table" and lualine.normal ~= nil, "lualine gets telar's colors")

if failures > 0 then
  os.exit(1)
end

print("theme_test: ok")
