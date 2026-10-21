local ui = require("telar.ui")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local Spaces = require("components.spaces")
local Tabs = require("components.tabs")
require("components.shortcuts")()

local background = ui.create("QtQuick", "Rectangle", {
  color = "#1b1723",
  radius = 10,
  ["border.color"] = "#393142",
  ["border.width"] = 1,
})

local workspace_name = ui.text({
  color = "#c4a7e7",
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12,
  ["font.weight"] = 600,
})

local status = ui.text({
  color = "#aca3bb",
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12,
})

local tabs = Tabs.new({ on_select = runtime.select_tab, on_move = runtime.move_tab })
local state = runtime.state()
local desktop_state = desktop.state()
local spaces = Spaces.new({
  activate = desktop.activate_space,
  remove = desktop.remove_space,
})

-- Keep the strip in the widest unobstructed region when a surface crosses a notch.
local function available_region()
  local safe = ui.surface.safe_area or {}
  local left = safe.left or 0
  local right = ui.surface.width - (safe.right or 0)
  local exclusions = {}

  for _, rectangle in ipairs(safe.exclusions or {}) do
    exclusions[#exclusions + 1] = rectangle
  end

  table.sort(exclusions, function(a, b)
    return a.x < b.x
  end)

  local best_left, best_right = left, left

  for _, rectangle in ipairs(exclusions) do
    local edge = math.max(left, math.min(right, rectangle.x))

    if edge - left > best_right - best_left then
      best_left, best_right = left, edge
    end

    left = math.max(left, math.min(right, rectangle.x + rectangle.width))
  end

  if right - left > best_right - best_left then
    best_left, best_right = left, right
  end

  return best_left + 8, math.max(0, best_right - best_left - 16)
end

local function layout()
  local left, width = available_region()
  local height = ui.surface.height
  local spaces_width = math.min(spaces.total_width or 0, width * 0.3)
  local label_width = math.min(140, width * 0.2) + spaces_width + 16
  local error_width = (state.error or desktop_state.error)
      and #state.tabs > 0
      and math.min(320, width * 0.35)
    or 0

  background.x = left
  background.y = 1
  background.width = width
  background.height = math.max(0, height - 2)
  spaces:set_geometry(left + 6, 4, spaces_width, height - 8)
  workspace_name.x = left + spaces_width + 18
  workspace_name.y = math.floor((height - workspace_name.implicitHeight) / 2)
  workspace_name.width = math.max(0, label_width - spaces_width - 26)
  status.x = error_width > 0 and left + width - error_width or left + label_width
  status.y = math.floor((height - status.implicitHeight) / 2)
  status.width = math.max(0, error_width > 0 and error_width - 12 or width - label_width - 12)
  tabs:set_geometry(
    left + label_width,
    4,
    math.max(0, width - label_width - error_width - 8),
    height - 8
  )
end

local function update(next_state)
  local previous_error = state.error
  local previously_had_tabs = #state.tabs > 0
  state = next_state
  workspace_name.text = state.workspace and state.workspace.name or "Telar"
  local error = state.error or desktop_state.error
  status.visible = #state.tabs == 0 or error ~= nil
  status.color = error and "#e6a2a7" or "#aca3bb"
  status.text = error
    or (not state.connected and "Connecting to runtime…")
    or (not desktop_state.available and "Waiting for macOS Spaces…")
    or (not state.workspace and "No runtime workspace is bound to this Space")
    or "Waiting for the active workspace…"
  tabs:update(state)

  if state.error ~= previous_error or previously_had_tabs ~= (#state.tabs > 0) then
    layout()
  end
end

spaces:update(desktop_state)
update(state)
layout()
desktop.on_change(function(next_state)
  desktop_state = next_state
  spaces:update(next_state)
  update(runtime.state())
  layout()
end)
runtime.on_change(update)
ui.on(ui.surface, "resize", layout)
ui.on(ui.surface, "safe_area_changed", layout)
ui.on(ui.surface, "screen_changed", layout)
