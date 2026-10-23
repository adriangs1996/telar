-- Run with LuaJIT from services/desktop-mode: luajit tests/terminal_ui.lua
local ui_directory = arg[1] or "ui"

local function background(opacity, color)
  local theme = assert(loadfile(ui_directory .. "/themes/dark.lua"))()
  theme.terminal.background_opacity = opacity
  theme.terminal.background = color or "#211b2f"
  local rectangle
  local ui = {
    surface = { options = {}, width = 800, height = 600 },
    on = function() end,
    animate = function() end,
    create = function(_, _, settings)
      rectangle = rectangle or settings
      return settings
    end,
    item = function(settings)
      return settings
    end,
    text = function(settings)
      assert(settings.opacity == nil)
      settings.implicitWidth, settings.implicitHeight = 0, 0
      return settings
    end,
  }
  local function shape()
    return {}
  end
  local modules = {
    ["telar.ui"] = ui,
    ["telar.theme"] = theme,
    ["telar.workbench"] = {},
    ["telar.runtime"] = {
      agents = function()
        return {}
      end,
      state = function()
        return { views = {} }
      end,
      on_agents = function() end,
      on_change = function() end,
    },
    agent_status = { new_glyph = shape },
    icons = { new = shape },
    color = assert(loadfile(ui_directory .. "/color.lua"))(),
  }
  local environment = setmetatable({
    require = function(name)
      return assert(modules[name], name)
    end,
  }, { __index = _G })
  setfenv(assert(loadfile(ui_directory .. "/workbench/init.lua")), environment)()
  assert(rectangle.opacity == nil)
  assert(rectangle["border.color"] == theme.colors.border)
  return rectangle.color
end

assert(background(0) == "#00211b2f")
assert(background(0.5) == "#80211b2f")
assert(background(1) == "#15131B")
assert(background(0.5, "#80211b2f") == "#40211b2f")
print("Terminal UI: one translucent pane fill with opaque borders and labels passed")
