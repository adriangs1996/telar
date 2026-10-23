-- Run with LuaJIT from services/desktop-mode: luajit tests/themes.lua
local ui_directory = arg[1] or "ui"
local configured
local environment = setmetatable({
  _telar_ui = {
    configure_theme = function(theme)
      configured = theme
    end,
  },
  _telar_io = {
    module_path = ui_directory .. "/?.lua;" .. ui_directory .. "/?/init.lua",
    traceback = debug.traceback,
    module_source = function(name, paths)
      for pattern in paths:gmatch("[^;]+") do
        local path = pattern:gsub("%?", (name:gsub("%.", "/")))
        local file = io.open(path, "r")

        if file then
          local source = file:read("*a")
          file:close()
          return { source = source, path = path }
        end
      end

      error("Module not found: " .. name)
    end,
  },
}, { __index = _G })
environment._G = environment
setfenv(assert(loadfile(ui_directory .. "/api.lua")), environment)()

local desktop = environment.require("telar.desktop")
local function equal(actual, expected)
  assert(type(actual) == type(expected))

  if type(expected) ~= "table" then
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
    return
  end

  for key, value in pairs(expected) do
    equal(actual[key], value)
  end

  for key in pairs(actual) do
    assert(expected[key] ~= nil, "Unexpected key " .. key)
  end
end

assert(configured.colors.ground == "#211b2f")
assert(configured.colors.chrome == "#1a1627")
assert(configured.colors.accent == "#aa87f5")
assert(configured.status.working.color == "#8caaee")
assert(configured.status.failed.background == "#4b2e40")
assert(configured.terminal.background == "#211b2f")
assert(configured.terminal.ansi.blue == "#8caaee")
assert(configured.terminal.ansi.bright_cyan == "#85c1dc")
assert(configured.terminal.cursor_color == "#aa87f5")
assert(configured.wallpaper.image == "ghostwire-neon-skyline.png")
assert(configured.terminal.background_opacity == 1)
assert(configured.terminal.font.thicken == false)
assert(configured.terminal.font.thicken_strength == 255)

-- A new GUI font setting must also be represented in the desktop's schema.
local gui_font = assert(io.open(ui_directory .. "/../../../src/client/config/GuiFont.zig", "r"))

for line in gui_font:lines() do
  local field = line:match("^([%w_]+):")

  if field then
    assert(configured.terminal.font[field] ~= nil, "Missing GUI font setting " .. field)
  end
end

gui_font:close()

local presets = {
  "cybervenom",
  "osaka-jade",
  "vesper",
  "catppuccin-latte",
  "catppuccin-frappe",
  "catppuccin-macchiato",
  "catppuccin-mocha",
  "tokyo-night",
  "pierre-dark",
  "pierre-dark-soft",
  "kanagawa-wave",
  "kanagawa-dragon",
  "kanagawa-dragon-vivid",
  "kanagawa-lotus",
  "terminal",
  "dark",
}
local base = environment.require("themes.dark")

-- Every preset must supply all its colors; missing roles must not inherit dark's palette.
local function complete(actual, schema)
  for key, value in pairs(schema) do
    if type(value) == "table" then
      if key ~= "font" then
        assert(type(actual[key]) == "table", "Missing group " .. key)
        complete(actual[key], value)
      end
    elseif type(value) == "string" and value:sub(1, 1) == "#" then
      assert(type(actual[key]) == "string", "Missing color " .. key)
      assert(actual[key]:match("^#%x%x%x%x%x%x$"), "Invalid color " .. key)
    end
  end
end

for _, name in ipairs(presets) do
  local tokens = environment.require("themes." .. name)
  complete(tokens.colors, base.colors)
  complete(tokens.status, base.status)
  complete(tokens.terminal, base.terminal)
  -- Bundled presets name a wallpaper shipped in assets/wallpapers.
  assert(not tokens.wallpaper.image:find("/", 1, true))
  local asset =
    assert(io.open(ui_directory .. "/../assets/wallpapers/" .. tokens.wallpaper.image, "rb"))
  asset:close()
  local resolved = desktop.theme({ preset = name })
  assert(resolved == configured)
  assert(resolved == environment.require("telar.theme"))
  assert(resolved.terminal.font.size == base.terminal.font.size)
  assert(resolved.terminal.background_opacity == 1)
end

local latte = desktop.theme({ preset = "catppuccin-latte" })
assert(latte.colors.ground == "#eff1f5")
assert(latte.terminal.ansi.bright_white == "#bcc0cc")
assert(latte.wallpaper.image == "catppuccin-latte-wisteria.png")
local overrides = desktop.theme({
  preset = "catppuccin-latte",
  colors = { accent = "#123456" },
  terminal = {
    background_opacity = 0.7,
    font = { size = 18, thicken = true, thicken_strength = 128 },
    cursor_color = "#abcdef",
  },
  wallpaper = { image = "" },
})
assert(overrides.colors.accent == "#123456")
assert(overrides.terminal.font.size == 18)
assert(overrides.terminal.cursor_color == "#abcdef")
assert(overrides.terminal.background_opacity == 0.7)
assert(overrides.terminal.font.thicken)
assert(overrides.terminal.font.thicken_strength == 128)
assert(overrides.wallpaper.image == "")
equal(desktop.theme({ preset = "catppuccin-latte" }), latte)

local previous = configured
for _, settings in ipairs({
  { preset = "missing" },
  { preset = "../cybervenom" },
  { preset = "palette" },
  { colors = { missing = "#123456" } },
  { colors = { accent = "#123" } },
  { terminal = { font = { size = 0 } } },
  { terminal = { background_opacity = -0.01 } },
  { terminal = { background_opacity = 1.01 } },
  { terminal = { background_opacity = 0 / 0 } },
  { terminal = { background_opacity = true } },
  { terminal = { font = { thicken = 1 } } },
  { terminal = { font = { thicken_strength = 0.5 } } },
  { terminal = { font = { thicken_strength = -1 } } },
  { terminal = { font = { thicken_strength = 256 } } },
  { terminal = { font = { family = string.char(0xC0, 0x80) } } },
  { terminal = { font = { style = string.char(0xED, 0xA0, 0x80) } } },
  { wallpaper = { image = false } },
}) do
  assert(not pcall(desktop.theme, settings))
  assert(configured == previous)
  assert(environment.require("telar.theme") == previous)
end

equal(desktop.theme(), desktop.theme({ preset = "cybervenom" }))
print("Desktop themes: presets, overrides and validation passed")
