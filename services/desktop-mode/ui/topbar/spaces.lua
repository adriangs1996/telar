local ui = require("telar.ui")
local theme = require("telar.theme")

local Spaces = {}
Spaces.__index = Spaces

function Spaces.new(options)
  local self = setmetatable({ views = {}, scroll = 0, width = 0, height = 0 }, Spaces)
  self.activate = options.activate
  self.create = options.create
  self.remove = options.remove
  self.root = ui.item({ clip = true })
  self.total_width = 0
  self.add = ui.create(
    "QtQuick",
    "Rectangle",
    { color = theme.colors.raised, radius = theme.radius.small },
    self.root
  )
  self.add_label = ui.text({
    parent = self.add,
    text = "+",
    color = theme.colors.accent,
    ["font.pixelSize"] = 18,
  })
  self.add.visible = self.create ~= nil

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

function Spaces:make_view()
  local view = {}
  view.panel = ui.create("QtQuick", "Rectangle", { radius = theme.radius.small }, self.root)
  view.label = ui.text({
    parent = view.panel,
    textFormat = "PlainText",
    ["font.pixelSize"] = 12,
    ["font.weight"] = 600,
  })

  view.close = ui.item({ parent = view.panel, width = 16 })
  view.close_label = ui.text({
    parent = view.close,
    text = "×",
    color = theme.colors.muted,
    ["font.pixelSize"] = 14,
  })

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
    view.removable = not space.workspace and not space.fullscreen and counts[space.display] > 1
    view.width = view.removable and 52 or 34
    view.close.visible = view.removable
    view.close_label.color = space.focused and theme.colors.on_accent or theme.colors.muted
    self.spaces_width = self.spaces_width + view.width + 4
    view.panel.visible = true
    view.label.text = tostring(space.index) .. (space.fullscreen and " ◇" or "")
    view.label.color = space.focused and theme.colors.on_accent or theme.colors.accent
    ui.animate(view.panel, "color", {
      to = space.focused and theme.colors.accent
        or (space.id == self.pending and theme.colors.border_strong or theme.colors.raised),
      duration_ms = 140,
    })
  end

  for index = self.count + 1, #self.views do
    self.views[index].panel.visible = false
  end

  self.total_width = self.spaces_width + (self.create and 34 or 0)
  self.add.opacity = self.busy and 0.4 or 1
  self:arrange()
end

function Spaces:arrange()
  self.scroll = math.max(0, math.min(self.scroll, (self.total_width or 0) - self.width))

  self.add.x = (self.spaces_width or 0) - self.scroll
  self.add.width = 34
  self.add.height = self.height
  self.add_label.x = math.floor((34 - self.add_label.implicitWidth) / 2)
  self.add_label.y = math.floor((self.height - self.add_label.implicitHeight) / 2)

  local offset = -self.scroll

  for index = 1, self.count or 0 do
    local view = self.views[index]
    view.panel.x = offset
    view.panel.width = view.width
    offset = offset + view.width + 4
    view.panel.height = self.height
    view.close.x = view.width - 18
    view.close.height = self.height
    view.close_label.x = math.floor((16 - view.close_label.implicitWidth) / 2)
    view.close_label.y = math.floor((self.height - view.close_label.implicitHeight) / 2)
    view.label.x = math.floor((34 - view.label.implicitWidth) / 2)
    view.label.y = math.floor((self.height - view.label.implicitHeight) / 2)
  end
end

function Spaces:set_geometry(x, y, width, height)
  self.width, self.height = width, height
  self.root.x, self.root.y = x, y
  self.root.width, self.root.height = width, height
  self:arrange()
end

return Spaces
