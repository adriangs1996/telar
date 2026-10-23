-- The top bar of a display: its Spaces and their workspaces, the tabs of the workspace on screen,
-- and whether the runtime answers.
local ui = require("telar.ui")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local theme = require("telar.theme")
local displays = require("displays")
local Spaces = require("topbar.spaces")
local Tabs = require("topbar.tabs")

local colors = theme.colors

local metrics = {
  inset = 1,
  item_height = 30,
  logo = 18,
  padding = 12,
  gap = 12,
  separator_height = 20,
  spaces_share = 0.45,
  dot = 7,
  status_width = 320,
  margin = 8,
}

-- Three warp threads crossed by two weft waves.
local logo_path =
  "M5 3v16M11 3v16M17 3v16 M2 8c3 0 3 2 6 2s3-2 6-2 3 2 6 2 M2 14c3 0 3-2 6-2s3 2 6 2 3-2 6-2"

local background = ui.create("QtQuick", "Rectangle", {
  color = colors.chrome,
  radius = theme.radius.large,
  ["border.color"] = colors.border,
  ["border.width"] = 1,
})

local logo = ui.path({
  path = logo_path,
  width = 22,
  height = 22,
  fillMode = "NoResize",
  scale = metrics.logo / 22,
  transformOrigin = "TopLeft",
  stroke = colors.accent,
  stroke_width = 1.8,
})

local separator = ui.create("QtQuick", "Rectangle", {
  width = 1,
  height = metrics.separator_height,
  color = colors.border,
})

local message = ui.text({
  color = colors.muted,
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12,
})

local status_dot = ui.create("QtQuick", "Rectangle", {
  width = metrics.dot,
  height = metrics.dot,
  radius = metrics.dot / 2,
})

local status = ui.text({
  textFormat = "PlainText",
  elide = "ElideLeft",
  horizontalAlignment = "AlignRight",
  ["font.pixelSize"] = 11,
})

local tabs = Tabs.new({ on_select = runtime.select_tab, on_move = runtime.move_tab })
local runtime_state = runtime.state()
local desktop_state = desktop.state()
local agents = runtime.agents()

-- What this display shows: the workspace on its visible Space and that workspace's tabs.
local function screen_state()
  local view, space = displays.view(runtime_state, desktop_state, displays.of(ui.surface))

  return {
    connected = runtime_state.connected,
    error = runtime_state.error,
    completed_request = runtime_state.completed_request,
    context = space and space.id,
    workspace = view and view.workspace,
    tabs = view and view.tabs or {},
    active_tab = view and view.active_tab,
    agents = agents,
  }
end

-- This display's Spaces, for the strip.
local function screen_spaces()
  local names = {}

  for _, workspace in ipairs(runtime_state.workspaces or {}) do
    names[workspace.id] = workspace.name
  end

  return {
    pending_space = desktop_state.pending_space,
    pending_operation = desktop_state.pending_operation,
    spaces = displays.spaces(desktop_state, displays.of(ui.surface)),
    names = names,
    agents = agents,
  }
end

local state = screen_state()
-- What the layout depends on besides the surface: relaying out cancels a tab drag.
local laid_out
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

  return best_left + metrics.margin, math.max(0, best_right - best_left - 2 * metrics.margin)
end

local function layout()
  laid_out = string.format("%g|%s", spaces.total_width or 0, status.text)
  local left, width = available_region()
  local height = ui.surface.height
  local item_y = (height - metrics.item_height) / 2
  local right = left + width - metrics.padding

  background.x = left
  background.y = metrics.inset
  background.width = width
  background.height = math.max(0, height - 2 * metrics.inset)

  logo.x = left + metrics.padding
  logo.y = (height - metrics.logo) / 2
  local x = logo.x + metrics.logo + metrics.gap

  status.width = math.min(metrics.status_width, status.implicitWidth)
  status.x = right - status.width
  status.y = (height - status.implicitHeight) / 2
  status_dot.x = status.x - 6 - metrics.dot
  status_dot.y = (height - metrics.dot) / 2
  right = status_dot.x - metrics.gap

  local spaces_width = math.min(spaces.total_width or 0, (right - x) * metrics.spaces_share)
  spaces:set_geometry(x, item_y, spaces_width, metrics.item_height)
  x = x + spaces_width + metrics.gap
  separator.x = x
  separator.y = (height - metrics.separator_height) / 2
  x = x + 1 + metrics.gap

  message.x = x
  message.y = (height - message.implicitHeight) / 2
  message.width = math.max(0, right - x)
  tabs:set_geometry(x, item_y, math.max(0, right - x), metrics.item_height)
end

local function update()
  state = screen_state()
  local error = state.error or desktop_state.error
  message.visible = #state.tabs == 0
  message.text = (not state.connected and "Connecting to runtime…")
    or (not desktop_state.available and "Waiting for macOS Spaces…")
    or (not state.workspace and "No runtime workspace is bound to this Space")
    or "Waiting for the active workspace…"
  status_dot.color = error and colors.error
    or (state.connected and theme.status.done.color or theme.status.blocked.color)
  status.color = error and colors.error or colors.muted
  status.text = error or (state.connected and "runtime" or "connecting")
  tabs:update(state)

  if laid_out ~= string.format("%g|%s", spaces.total_width or 0, status.text) then
    layout()
  end
end

local function refresh()
  spaces:update(screen_spaces())
  update()
end

refresh()
desktop.on_change(function(next_state)
  desktop_state = next_state
  refresh()
end)
runtime.on_change(function(next_state)
  runtime_state = next_state
  refresh()
end)
runtime.on_agents(function(next_agents)
  agents = next_agents
  refresh()
end)
ui.on(ui.surface, "resize", layout)
ui.on(ui.surface, "safe_area_changed", layout)
ui.on(ui.surface, "screen_changed", refresh)
