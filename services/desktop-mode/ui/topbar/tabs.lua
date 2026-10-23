local ui = require("telar.ui")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")
local Icons = require("icons")
local Color = require("color")

local Tabs = {}
Tabs.__index = Tabs

local gap = 6
local drag_threshold = 6
local underline = 2
local icon_size = 14
local colors = {
  selected = theme.colors.selected,
  hover = theme.colors.hover,
  idle = Color.fade(theme.colors.chrome, 0),
  text = theme.colors.text,
  muted = theme.colors.muted,
  label = theme.colors.label,
  accent = theme.colors.accent,
}

local function copy(values)
  local result = {}

  for index, value in ipairs(values) do
    result[index] = value
  end

  return result
end

local function equal(left, right)
  return table.concat(left, ",") == table.concat(right, ",")
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function animate(item, property, value)
  ui.animate(item, property, { to = value, duration_ms = 180, easing = "out_cubic" })
end

local function context(state)
  local workspace = state.workspace

  if not workspace then
    return ""
  end

  return (state.context or "") .. ":" .. workspace.kind .. ":" .. workspace.id
end

local function label(tab)
  local name = tab.label ~= "" and tab.label or "Terminal"
  local foreground = tab.foregrounds[1]
  foreground = foreground and foreground.name

  if foreground and foreground ~= "" and foreground ~= name then
    return name .. " · " .. foreground
  end

  return name
end

function Tabs.new(options)
  local self = setmetatable({
    viewport = ui.item({ clip = true }),
    views = {},
    pool = {},
    order = {},
    scroll = 0,
    width = 0,
    total_width = 0,
    height = 28,
    x = 0,
    y = 4,
    on_select = options.on_select,
    on_move = options.on_move,
  }, Tabs)

  ui.on(self.viewport, "scroll", function(event)
    local delta = event.pixel_delta.x

    if delta == 0 then
      delta = event.pixel_delta.y
    end

    if delta == 0 then
      delta = (event.angle_delta.x + event.angle_delta.y) / 3
    end

    self.scroll = clamp(self.scroll - delta, 0, math.max(0, self.total_width - self.width))
    self:arrange(false)
    event:accept()
  end)

  return self
end

function Tabs:paint(view)
  local selected = self.state and view.id == self.state.active_tab
  animate(
    view.panel,
    "color",
    selected and colors.selected or view.hovered and colors.hover or colors.idle
  )
  view.title.color = selected and colors.text or colors.muted
  view.icon.stroke = selected and colors.accent or colors.label
  ui.animate(view.underline, "opacity", { to = selected and 1 or 0, duration_ms = 180 })
end

-- A tab with an agent at work shows that agent's status where the terminal icon was.
function Tabs:paint_agent(view, agents)
  local agent = AgentStatus.most_urgent(agents or {}, function(candidate)
    return candidate.tab == view.id and AgentStatus.active(candidate)
  end)

  view.glyph.visible = agent ~= nil
  view.icon.visible = agent == nil

  if agent then
    AgentStatus.paint_glyph(view.glyph, agent)
  end
end

function Tabs:make_view()
  local view = {
    panel = ui.create("QtQuick", "Rectangle", {
      height = self.height,
      radius = theme.radius.small,
      color = colors.idle,
    }, self.viewport),
  }

  view.icon = Icons.new("terminal", { parent = view.panel, color = colors.label, size = icon_size })
  view.glyph = AgentStatus.new_glyph(view.panel, icon_size)
  view.underline = ui.create("QtQuick", "Rectangle", {
    height = underline,
    radius = underline / 2,
    color = colors.accent,
    opacity = 0,
  }, view.panel)
  view.icon.x, view.glyph.x = 12, 12

  view.title = ui.text({
    parent = view.panel,
    x = 34,
    color = colors.text,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = 13,
  })

  ui.on(view.panel, "hover", function(event)
    view.hovered = event.inside
    self:paint(view)
  end)

  ui.on(view.panel, "pointer_down", function(event)
    if event.button ~= "left" or self.pending or self.drag then
      return
    end

    self.drag = {
      id = view.id,
      origin = event.surface_position.x,
      offset = event.x,
      pointer_id = event.pointer_id,
      device_id = event.device_id,
      context = context(self.state),
      order = copy(self.order),
      active = false,
    }

    event:capture_pointer()
    event:stop_propagation()
  end)

  ui.on(view.panel, "pointer_move", function(event)
    self:drag_move(event)
  end)

  ui.on(view.panel, "pointer_up", function(event)
    self:drag_end(event)
  end)

  ui.on(view.panel, "pointer_cancel", function()
    self:cancel_drag()
  end)

  return view
end

function Tabs:cancel_drag()
  if not self.drag then
    return
  end

  if self.views[self.drag.id] then
    self.views[self.drag.id].panel.z = 0
  end

  self.drag = nil
  self.preview = nil
  self:arrange(true)
end

function Tabs:matches(event)
  return self.drag
    and self.drag.pointer_id == event.pointer_id
    and self.drag.device_id == event.device_id
end

function Tabs:drag_move(event)
  if not self:matches(event) then
    return
  end

  local drag = self.drag

  if not drag.active and math.abs(event.surface_position.x - drag.origin) < drag_threshold then
    return
  end

  local view = self.views[drag.id]
  drag.active = true
  view.panel.z = 1

  local pointer = event.surface_position.x - self.x

  if pointer < 24 then
    self.scroll = math.max(0, self.scroll - 12)
  elseif pointer > self.width - 24 then
    self.scroll = math.min(math.max(0, self.total_width - self.width), self.scroll + 12)
  end

  local position = clamp(pointer + self.scroll - drag.offset, 0, self.total_width - view.width)
  local center = position + view.width / 2
  local order = {}
  local insertion = 1
  local cursor = 0

  for _, id in ipairs(self.order) do
    if id ~= drag.id then
      order[#order + 1] = id

      if center > cursor + self.views[id].width / 2 then
        insertion = #order + 1
      end

      cursor = cursor + self.views[id].width + gap
    end
  end

  table.insert(order, insertion, drag.id)
  self.preview = order
  self:arrange(true)
  view.target_x = nil
  ui.animate(view.panel, "x", { to = position - self.scroll, duration_ms = 0 })
  event:accept()
end

function Tabs:drag_end(event)
  if event.button ~= "left" or not self:matches(event) then
    return
  end

  local drag = self.drag
  local order = self.preview or self.order
  local inside = event.surface_position.x >= self.x
    and event.surface_position.x <= self.x + self.width
    and event.surface_position.y >= self.y
    and event.surface_position.y <= self.y + self.height
  self.drag = nil
  self.views[drag.id].panel.z = 0
  event:release_pointer()
  event:accept()

  if not inside or context(self.state) ~= drag.context then
    self.preview = nil
  elseif drag.active and not equal(order, self.order) then
    local index

    for position, id in ipairs(order) do
      if id == drag.id then
        index = position
        break
      end
    end

    local target = index < #order and { before = order[index + 1] } or { after = order[index - 1] }
    local ok, result = pcall(self.on_move, drag.id, target)

    if ok then
      self.pending = result
    else
      self.preview = nil
      print("Tab move failed: " .. tostring(result))
    end
  else
    self.preview = nil

    if not drag.active then
      local ok, message = pcall(self.on_select, drag.id)

      if not ok then
        print("Tab selection failed: " .. tostring(message))
      end
    end
  end

  self:arrange(true)
end

function Tabs:arrange(animated)
  local order = self.preview or self.order
  local cursor = -self.scroll

  for _, id in ipairs(order) do
    local view = self.views[id]

    if not self.drag or not self.drag.active or self.drag.id ~= id then
      if animated and view.placed then
        if view.target_x ~= cursor then
          animate(view.panel, "x", cursor)
        end
      else
        ui.animate(view.panel, "x", { to = cursor, duration_ms = 0 })
      end

      view.target_x = cursor
      view.placed = true
    end

    cursor = cursor + view.width + gap
  end
end

function Tabs:reveal_active()
  local cursor = 0

  for _, id in ipairs(self.order) do
    local view = self.views[id]

    if id == self.state.active_tab then
      if cursor < self.scroll then
        self.scroll = cursor
      elseif cursor + view.width > self.scroll + self.width then
        self.scroll = cursor + view.width - self.width
      end

      return
    end

    cursor = cursor + view.width + gap
  end
end

function Tabs:update(state)
  local order = {}
  local present = {}
  local previous = self.state

  for _, tab in ipairs(state.tabs) do
    order[#order + 1] = tab.id
    present[tab.id] = true
  end

  if self.drag and (context(state) ~= self.drag.context or not equal(order, self.drag.order)) then
    self:cancel_drag()
  end

  if
    self.pending
    and (state.completed_request == self.pending or context(state) ~= context(previous))
  then
    self.pending = nil
    self.preview = nil
  end

  for id, view in pairs(self.views) do
    if not present[id] then
      view.panel.visible = false
      view.placed = false
      view.hovered = false
      self.pool[#self.pool + 1] = view
      self.views[id] = nil
    end
  end

  self.state = state
  self.order = order
  self.total_width = 0

  for _, tab in ipairs(state.tabs) do
    local view = self.views[tab.id]

    if not view then
      view = table.remove(self.pool) or self:make_view()
      self.views[tab.id] = view
    end

    view.id = tab.id
    view.title.text = label(tab)
    view.title.y = (self.height - view.title.implicitHeight) / 2
    view.width = clamp(view.title.implicitWidth + 48, 100, 240)
    view.panel.width = view.width
    view.panel.height = self.height
    view.title.width = view.width - 44
    view.underline.x = 10
    view.underline.width = view.width - 20
    view.underline.y = self.height - underline
    view.icon.y = (self.height - icon_size) / 2
    view.glyph.y = view.icon.y
    self:paint_agent(view, state.agents)
    view.panel.visible = true
    self.total_width = self.total_width + view.width + gap
    self:paint(view)
  end

  self.total_width = math.max(0, self.total_width - gap)
  self.scroll = clamp(self.scroll, 0, math.max(0, self.total_width - self.width))

  if not self.drag and (not previous or previous.active_tab ~= state.active_tab) then
    self:reveal_active()
  end

  self:arrange(previous ~= nil)
end

function Tabs:set_geometry(x, y, width, height)
  self:cancel_drag()
  local resized = height ~= self.height
  self.x, self.y, self.width, self.height = x, y, width, height
  ui.set(self.viewport, "x", x)
  ui.set(self.viewport, "y", y)
  ui.set(self.viewport, "width", width)
  ui.set(self.viewport, "height", height)

  if self.state and resized then
    self:update(self.state)
  elseif self.state then
    self.scroll = clamp(self.scroll, 0, math.max(0, self.total_width - width))
    self:reveal_active()
    self:arrange(false)
  end
end

return Tabs
