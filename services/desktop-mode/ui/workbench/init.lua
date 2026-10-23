-- A pane's chrome: its frame, and a header that names what runs in it and how its agent is doing.
local ui = require("telar.ui")
local runtime = require("telar.runtime")
local workbench = require("telar.workbench")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")
local Icons = require("icons")
local Color = require("color")
local options = ui.surface.options
local colors = theme.colors
local opacity = theme.terminal.background_opacity

local metrics = {
  -- Until the workbench reports where the terminal starts.
  header_height = options.header_height or 34,
  padding_x = 12,
  icon = 14,
  gap = 8,
  chip_padding = 8,
  chip_height = 20,
  close = 22,
  close_icon = 12,
  cwd_width = 160,
  hover_ms = 120,
  focus_ms = 160,
}

local function rectangle(properties)
  local parent = properties.parent
  properties.parent = nil

  return ui.create("QtQuick", "Rectangle", properties, parent)
end

-- One background covers the pane, including padding. Text and the border keep their opacity.
local background = rectangle({
  color = opacity == 1 and colors.chrome or Color.fade(theme.terminal.background, opacity),
  radius = theme.radius.medium,
  ["border.width"] = 1,
  ["border.color"] = colors.border,
})

local band = rectangle({
  parent = background,
  x = 1,
  y = 1,
  topLeftRadius = theme.radius.medium - 1,
  topRightRadius = theme.radius.medium - 1,
  bottomLeftRadius = 0,
  bottomRightRadius = 0,
  color = Color.fade(colors.chrome, opacity),
})

local divider = rectangle({ parent = background, x = 1, height = 1, color = colors.border })
local glyph = AgentStatus.new_glyph(background, metrics.icon)
local shell_icon = Icons.new("terminal", { parent = background, color = colors.label, size = 14 })

local name = ui.text({
  parent = background,
  color = colors.text,
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12.5,
  ["font.weight"] = 600,
})

local title = ui.text({
  parent = background,
  color = colors.muted,
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12,
})

local chip = rectangle({
  parent = background,
  height = metrics.chip_height,
  radius = theme.radius.small,
  visible = false,
})

local chip_label = ui.text({
  parent = chip,
  textFormat = "PlainText",
  x = metrics.chip_padding,
  ["font.pixelSize"] = 11,
})

local cwd = ui.text({
  parent = background,
  color = colors.label,
  textFormat = "PlainText",
  elide = "ElideLeft",
  horizontalAlignment = "AlignRight",
  ["font.pixelSize"] = 11,
})

if theme.fonts.mono ~= "" then
  cwd["font.family"] = theme.fonts.mono
end

local close = rectangle({
  parent = background,
  width = metrics.close,
  height = metrics.close,
  radius = metrics.close / 2,
  color = "transparent",
})

local close_icon = Icons.new("close", {
  parent = close,
  color = colors.muted,
  size = metrics.close_icon,
})
close_icon.x = (metrics.close - metrics.close_icon) / 2
close_icon.y = (metrics.close - metrics.close_icon) / 2

-- Focus and urgency draw a second frame over the plain one, which fades in and out.
local highlight = rectangle({
  parent = background,
  color = "transparent",
  radius = theme.radius.medium,
  opacity = 0,
  ["border.width"] = 1.5,
})

local header = ui.item({ parent = background })
local resize = ui.item({ parent = background, width = 8, height = 8 })
local drag
local pane_state = {}
local runtime_state = runtime.state()
local agents = runtime.agents()
local agent
local cancel_tick
local paint

local function find_agent()
  for _, candidate in ipairs(agents) do
    if candidate.pane == pane_state.pane then
      return candidate
    end
  end
end

-- The process in front of the pane, from its tab in the runtime's catalog.
local function foreground()
  for _, view in ipairs(runtime_state.views or {}) do
    for _, tab in ipairs(view.tabs) do
      for _, entry in ipairs(tab.foregrounds) do
        if entry.pane == pane_state.pane then
          return entry.name
        end
      end
    end
  end
end

local function header_height()
  local content = pane_state.content

  return content and content.y or metrics.header_height
end

local function schedule_tick()
  if cancel_tick then
    cancel_tick()
    cancel_tick = nil
  end

  if agent and chip.visible then
    cancel_tick = ui.after(AgentStatus.next_change_ms(agent), function()
      cancel_tick = nil
      agents = runtime.agents()
      agent = find_agent()
      paint()
    end)
  end
end

-- An agent that needs the person colors the frame even when the pane is not focused.
paint = function()
  local width = pane_state.width or 0
  local height = header_height()
  local palette = agent and AgentStatus.colors(agent)
  local urgent = agent and AgentStatus.group(agent) == "needs_input"
  local center = function(item_height)
    return math.floor((height - item_height) / 2)
  end

  band.width = math.max(0, width - 2)
  band.height = math.max(0, height - 1)
  band.color = Color.fade(urgent and palette.background or colors.chrome, opacity)
  divider.y = height
  divider.width = math.max(0, width - 2)
  divider.color = urgent and palette.border or colors.border
  glyph.visible = agent ~= nil
  shell_icon.visible = agent == nil
  chip.visible = agent ~= nil and agent.status ~= "ready"

  local icon = agent and glyph or shell_icon
  icon.x = metrics.padding_x
  icon.y = center(metrics.icon)

  if agent then
    AgentStatus.paint_glyph(glyph, agent)
    name.text = agent.name
    title.text = AgentStatus.title(agent) or ""
    cwd.text = agent.cwd_label
  else
    name.text = foreground() or "Terminal"
    title.text = ""
    cwd.text = ""
  end

  close.x = width - metrics.padding_x - metrics.close + 4
  close.y = center(metrics.close)
  local right = close.x - metrics.gap
  cwd.visible = cwd.text ~= ""

  if cwd.visible then
    cwd.width = math.min(metrics.cwd_width, cwd.implicitWidth)
    cwd.x = right - cwd.width
    cwd.y = center(cwd.implicitHeight)
    right = cwd.x - metrics.gap - 4
  end

  if chip.visible then
    chip.color = palette.background
    chip["border.width"] = 1
    chip["border.color"] = Color.fade(palette.border, 0.6)
    chip_label.color = palette.text
    chip_label.text = agent.status == "working" and AgentStatus.corner(agent)
      or (AgentStatus.label(agent) .. " · " .. AgentStatus.age(agent.status_age_s))
    chip.width = chip_label.implicitWidth + 2 * metrics.chip_padding
    chip.x = right - chip.width
    chip.y = center(metrics.chip_height)
    chip_label.y = math.floor((metrics.chip_height - chip_label.implicitHeight) / 2)
    right = chip.x - metrics.gap
  end

  name.x = metrics.padding_x + metrics.icon + metrics.gap
  name.y = center(name.implicitHeight)
  name.width = math.max(0, math.min(name.implicitWidth, right - name.x))
  title.visible = title.text ~= ""
  title.x = name.x + name.width + metrics.gap
  title.y = center(title.implicitHeight)
  title.width = math.max(0, right - title.x)

  header.width = math.max(0, close.x - 4)
  header.height = height
  local highlighted = urgent or pane_state.focused

  if highlighted then
    highlight["border.color"] = urgent and palette.border or colors.accent
  end

  ui.animate(highlight, "opacity", { to = highlighted and 1 or 0, duration_ms = metrics.focus_ms })
  schedule_tick()
end

-- Reads one snapshot: each ui.surface field read builds the whole surface state.
local function update(state)
  local moved = state.pane ~= pane_state.pane
  pane_state = state
  background.width = state.width
  background.height = state.height
  highlight.width = state.width
  highlight.height = state.height
  resize.x = state.width - 8
  resize.y = state.height - 8

  if moved then
    agent = find_agent()
  end

  paint()
end

runtime.on_agents(function(next_agents)
  agents = next_agents
  agent = find_agent()
  paint()
end)

runtime.on_change(function(next_state)
  runtime_state = next_state

  if not agent then
    paint()
  end
end)

-- The pane's own state carries its size, focus and pane, so a change elsewhere in the
-- workbench does not run every pane's update.
ui.on(ui.surface, "state_changed", function(event)
  update(event.value)
end)

ui.on(header, "pointer_down", function(event)
  workbench.command("focus")
  if ui.surface.floating then
    drag = { position = event.global_position, frame = ui.surface.geometry }
    event:capture_pointer()
  end
  event:accept()
end)

ui.on(resize, "pointer_down", function(event)
  if ui.surface.floating then
    drag = { position = event.global_position, frame = ui.surface.geometry, resize = true }
    event:capture_pointer()
  end
end)

local function move(event)
  if not drag then
    return
  end
  local area = ui.surface.area
  local dx = event.global_position.x - drag.position.x
  local dy = event.global_position.y - drag.position.y
  workbench.command("frame", {
    frame = {
      x = (drag.frame.x - area.x + (drag.resize and 0 or dx)) / area.width,
      y = (drag.frame.y - area.y + (drag.resize and 0 or dy)) / area.height,
      width = math.max(1, drag.frame.width + (drag.resize and dx or 0)) / area.width,
      height = math.max(1, drag.frame.height + (drag.resize and dy or 0)) / area.height,
    },
  })
  event:accept()
end

for _, item in ipairs({ header, resize }) do
  ui.on(item, "pointer_move", move)
  ui.on(item, "pointer_up", function()
    drag = nil
  end)
  ui.on(item, "pointer_cancel", function()
    drag = nil
  end)
end

ui.on(close, "hover", function(event)
  ui.animate(close, "color", {
    to = event.inside and colors.hover or Color.fade(colors.hover, 0),
    duration_ms = metrics.hover_ms,
  })
  close_icon.stroke = event.inside and colors.text or colors.muted
end)

ui.on(close, "click", function(event)
  workbench.command("close")
  event:accept()
end)

local initial = ui.surface
update({
  width = initial.width,
  height = initial.height,
  pane = initial.pane,
  focused = initial.focused,
  content = initial.content,
})
