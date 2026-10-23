-- The strip of a display's Spaces: each shows its Mission Control number, the workspace it holds
-- and a dot in the color of that workspace's most urgent agent.
local ui = require("telar.ui")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")
local Icons = require("icons")
local Color = require("color")

local colors = theme.colors

local Spaces = {}
Spaces.__index = Spaces

local metrics = {
  badge = 20,
  padding_left = 5,
  padding_right = 10,
  gap = 8,
  dot = 7,
  close = 16,
  name_width = 140,
  spacing = 4,
  add = 30,
  hover_ms = 140,
}

local function rectangle(properties)
  local parent = properties.parent
  properties.parent = nil

  return ui.create("QtQuick", "Rectangle", properties, parent)
end

function Spaces.new(options)
  local self = setmetatable({ views = {}, scroll = 0, width = 0, height = 0 }, Spaces)
  self.activate = options.activate
  self.create = options.create
  self.remove = options.remove
  self.root = ui.item({ clip = true })
  self.total_width = 0
  self.add = rectangle({
    parent = self.root,
    color = "transparent",
    radius = theme.radius.small,
    visible = self.create ~= nil,
  })
  self.add_icon = Icons.new("plus", { parent = self.add, color = colors.muted, size = 12 })

  ui.on(self.add, "pointer_up", function(event)
    if event.button == "left" and self.create and not self.busy then
      self.create()
      event:stop_propagation()
    end
  end)

  ui.on(self.root, "scroll", function(event)
    local delta = event.pixel_delta.x + event.pixel_delta.y

    if delta == 0 then
      delta = (event.angle_delta.x + event.angle_delta.y) / 3
    end

    self.scroll = math.max(0, math.min(self.total_width - self.width, self.scroll - delta))
    self:arrange()
    event:stop_propagation()
  end)

  return self
end

function Spaces:paint(view)
  local fill = view.focused and colors.selected
    or (view.pending and colors.border_strong)
    or (view.hovered and colors.hover)
    or Color.fade(colors.chrome, 0)

  ui.animate(view.panel, "color", { to = fill, duration_ms = metrics.hover_ms })
  view.badge.color = view.focused and colors.accent or colors.raised
  view.number.color = view.focused and colors.on_accent or colors.muted
  view.label.color = view.focused and colors.text or colors.muted
end

function Spaces:make_view()
  local view = {}
  view.panel = rectangle({ parent = self.root, radius = theme.radius.small + 3 })
  view.badge = rectangle({
    parent = view.panel,
    x = metrics.padding_left,
    width = metrics.badge,
    height = metrics.badge,
    radius = theme.radius.small,
  })
  view.number = ui.text({
    parent = view.badge,
    ["font.pixelSize"] = 11,
    ["font.weight"] = 600,
  })
  view.label = ui.text({
    parent = view.panel,
    textFormat = "PlainText",
    elide = "ElideRight",
    x = metrics.padding_left + metrics.badge + metrics.gap,
    ["font.pixelSize"] = 13,
  })
  view.dot = rectangle({
    parent = view.panel,
    width = metrics.dot,
    height = metrics.dot,
    radius = metrics.dot / 2,
  })
  view.close = ui.item({ parent = view.panel, width = metrics.close })
  view.close_icon = Icons.new("close", { parent = view.close, color = colors.muted, size = 10 })

  ui.on(view.panel, "hover", function(event)
    view.hovered = event.inside
    self:paint(view)
  end)

  ui.on(view.close, "pointer_up", function(event)
    if event.button == "left" and view.removable and not self.busy then
      self.remove(view.id)
      event:stop_propagation()
    end
  end)

  ui.on(view.panel, "pointer_up", function(event)
    if event.button == "middle" and view.removable and not self.busy then
      self.remove(view.id)
      event:stop_propagation()
    elseif event.button == "left" and not self.busy then
      self.activate(view.id)
      event:stop_propagation()
    end
  end)

  return view
end

-- `state.names` maps workspace IDs to names; `state.agents` lists the runtime's agents.
function Spaces:update(state)
  self.pending = state.pending_space
  self.busy = state.pending_space or state.pending_operation
  local counts = {}

  for _, space in ipairs(state.spaces) do
    if not space.fullscreen then
      counts[space.display] = (counts[space.display] or 0) + 1
    end
  end

  self.count = #state.spaces
  self.spaces_width = 0

  for index, space in ipairs(state.spaces) do
    local view = self.views[index] or self:make_view()
    self.views[index] = view
    view.id = space.id
    view.focused = space.focused
    view.pending = space.id == self.pending
    view.removable = not space.workspace and not space.fullscreen and counts[space.display] > 1
    view.number.text = tostring(space.index)
    view.label.text = space.fullscreen and "Full screen"
      or (space.workspace and state.names[space.workspace])
      or ""
    view.label.width = math.min(metrics.name_width, view.label.implicitWidth)

    local agent = space.workspace
      and AgentStatus.most_urgent(state.agents, function(candidate)
        return candidate.workspace == space.workspace and AgentStatus.active(candidate)
      end)

    view.dot.visible = agent ~= nil

    if agent then
      view.dot.color = AgentStatus.colors(agent).color
    end

    local width = metrics.padding_left + metrics.badge

    if view.label.text ~= "" then
      width = width + metrics.gap + view.label.width
    end

    if view.dot.visible then
      view.dot.x = width + metrics.gap
      width = view.dot.x + metrics.dot
    end

    view.close.visible = view.removable

    if view.removable then
      view.close.x = width + 4
      width = view.close.x + metrics.close
    end

    view.width = width + (view.label.text ~= "" and metrics.padding_right or metrics.padding_left)
    self.spaces_width = self.spaces_width + view.width + metrics.spacing
    view.panel.visible = true
    self:paint(view)
  end

  for index = self.count + 1, #self.views do
    self.views[index].panel.visible = false
  end

  self.total_width = self.spaces_width + (self.create and metrics.add or 0)
  self.add.opacity = self.busy and 0.4 or 1
  self:arrange()
end

function Spaces:arrange()
  self.scroll = math.max(0, math.min(self.scroll, (self.total_width or 0) - self.width))

  self.add.x = (self.spaces_width or 0) - self.scroll
  self.add.width = metrics.add
  self.add.height = self.height
  self.add_icon.x = (metrics.add - 12) / 2
  self.add_icon.y = (self.height - 12) / 2

  local offset = -self.scroll

  for index = 1, self.count or 0 do
    local view = self.views[index]
    view.panel.x = offset
    view.panel.width = view.width
    view.panel.height = self.height
    offset = offset + view.width + metrics.spacing
    view.badge.y = (self.height - metrics.badge) / 2
    view.number.x = (metrics.badge - view.number.implicitWidth) / 2
    view.number.y = (metrics.badge - view.number.implicitHeight) / 2
    view.label.y = (self.height - view.label.implicitHeight) / 2
    view.dot.y = (self.height - metrics.dot) / 2
    view.close.height = self.height
    view.close_icon.x = (metrics.close - 10) / 2
    view.close_icon.y = (self.height - 10) / 2
  end
end

function Spaces:set_geometry(x, y, width, height)
  self.width, self.height = width, height
  self.root.x, self.root.y = x, y
  self.root.width, self.root.height = width, height
  self:arrange()
end

return Spaces
