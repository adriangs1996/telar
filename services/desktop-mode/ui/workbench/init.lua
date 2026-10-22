local ui = require("telar.ui")
local runtime = require("telar.runtime")
local workbench = require("telar.workbench")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")
local options = ui.surface.options
local colors = theme.colors
local header_height = options.header_height or 28
local title_x = 12
local chip_padding = 8
local chip_height = 20

local background = ui.create("QtQuick", "Rectangle", {
  color = colors.chrome,
  radius = theme.radius.medium,
  ["border.width"] = 1,
  ["border.color"] = colors.border,
})

local glyph = AgentStatus.new_glyph()
glyph.visible = false

local title = ui.text({
  color = colors.text,
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = 12,
  x = title_x,
  y = 6,
})

local chip = ui.create("QtQuick", "Rectangle", {
  height = chip_height,
  radius = theme.radius.small,
  visible = false,
})

local chip_label = ui.text({
  parent = chip,
  textFormat = "PlainText",
  x = chip_padding,
  ["font.pixelSize"] = 11,
})

local close = ui.text({
  text = "×",
  color = colors.muted,
  y = 4,
  ["font.pixelSize"] = 16,
})

local header = ui.item({ height = header_height })
local resize = ui.item({ width = 8, height = 8 })
local drag
local pane_state = {}
local agents = runtime.agents()
local agent

local function find_agent()
  for _, candidate in ipairs(agents) do
    if candidate.pane == pane_state.pane then
      return candidate
    end
  end
end

-- An agent that needs the person colors the border even when the pane is not focused.
local function paint()
  local width = pane_state.width or 0
  local palette = agent and AgentStatus.colors(agent)
  local urgent = agent and AgentStatus.group(agent) == "needs_input"
  local text_x = title_x

  glyph.visible = agent ~= nil
  chip.visible = agent ~= nil and agent.status ~= "ready"

  if agent then
    AgentStatus.paint_glyph(glyph, agent)
    glyph.x = title_x
    glyph.y = math.floor((header_height - AgentStatus.glyph_size) / 2)
    text_x = title_x + AgentStatus.glyph_size + 8
    title.text = agent.name .. "  " .. AgentStatus.title(agent)
    chip.color = palette.background
    chip_label.color = palette.text
    chip_label.text = AgentStatus.label(agent) .. " · " .. AgentStatus.age(agent.status_age_s)
    chip.width = chip_label.implicitWidth + 2 * chip_padding
    chip.x = width - 32 - chip.width
    chip.y = math.floor((header_height - chip_height) / 2)
    chip_label.y = math.floor((chip_height - chip_label.implicitHeight) / 2)
  else
    title.text = pane_state.pane and ("Pane " .. pane_state.pane) or "Telar"
  end

  title.x = text_x
  title.width = math.max(0, (chip.visible and chip.x or width - 32) - text_x - 8)
  background["border.color"] = (urgent and palette.border)
    or (pane_state.focused and colors.accent)
    or colors.border
end

-- Reads one snapshot: each ui.surface field read builds the whole surface state.
local function update(state)
  local moved = state.pane ~= pane_state.pane
  pane_state = state
  background.width = state.width
  background.height = state.height
  header.width = state.width - 32
  close.x = state.width - 24
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

ui.on(close, "click", function(event)
  workbench.command("close")
  event:accept()
end)

update({
  width = ui.surface.width,
  height = ui.surface.height,
  pane = ui.surface.pane,
  focused = ui.surface.focused,
})
