local ui = require("telar.ui")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local displays = require("displays")
local options = ui.surface.options

local colors = {
  background = "#1b1723",
  border = "#393142",
  text = "#e0d9ea",
  muted = "#aca3bb",
  accent = "#c4a7e7",
  row = "#231d2c",
  hover = "#32283f",
  selected = "#443351",
  pending = "#574361",
  error = "#e6a2a7",
}

for name, value in pairs(options.colors or {}) do
  colors[name] = value
end

local metrics = {
  padding = 14,
  radius = 10,
  title_size = 16,
  label_size = 13,
  detail_size = 11,
  list_top = 72,
  footer_height = 44,
  row_height = 52,
  row_gap = 6,
  row_padding = 12,
  detail_top = 29,
  transition_ms = 140,
  wheel_step = 120,
}

local background = ui.create("QtQuick", "Rectangle", {
  color = colors.background,
  radius = metrics.radius,
  ["border.color"] = colors.border,
  ["border.width"] = 1,
})

local title = ui.text({
  text = options.title or "Telar",
  color = colors.text,
  ["font.pixelSize"] = metrics.title_size,
  ["font.weight"] = 600,
})

local heading = ui.text({ color = colors.muted, ["font.pixelSize"] = metrics.detail_size })
local viewport = ui.item({ clip = true })
local content = ui.item({ parent = viewport })
local status = ui.text({
  textFormat = "PlainText",
  elide = "ElideRight",
  ["font.pixelSize"] = metrics.detail_size,
})

local state = runtime.state()
local desktop_state = desktop.state()
local rows = {}
local count = 0
local scroll = 0

local function busy()
  return not state.connected
    or not desktop_state.available
    or desktop_state.pending_space
    or desktop_state.pending_operation
end

-- Every change repaints every row, but a row only touches what differs from its last paint: a
-- Space switch changes two rows, and restarting the other rows' animations is wasted work.
local function paint(row)
  local color = row.selected and colors.selected
    or (row.space == desktop_state.pending_space and row.space and colors.pending)
    or (row.hovered and colors.hover)
    or colors.row
  local opacity = row.space and not busy() and 1 or 0.55
  local name_color = row.selected and colors.accent or colors.text

  if row.painted_opacity ~= opacity then
    row.painted_opacity = opacity
    row.panel.opacity = opacity
  end

  if row.painted_name_color ~= name_color then
    row.painted_name_color = name_color
    row.name.color = name_color
  end

  if row.painted_color ~= color then
    row.painted_color = color
    ui.animate(row.panel, "color", { to = color, duration_ms = metrics.transition_ms })
  end
end

local function make_row()
  local row = {}
  row.panel = ui.create("QtQuick", "Rectangle", { radius = metrics.radius }, content)
  row.name = ui.text({
    parent = row.panel,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.label_size,
    ["font.weight"] = 600,
  })
  row.detail = ui.text({
    parent = row.panel,
    color = colors.muted,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.detail_size,
  })

  ui.on(row.panel, "hover", function(event)
    row.hovered = event.inside
    paint(row)
  end)

  ui.on(row.panel, "click", function(event)
    if event.button == "left" and row.space and not busy() then
      desktop.activate_space(row.space)
      event:stop_propagation()
    end
  end)

  return row
end

local function arrange()
  local stride = metrics.row_height + metrics.row_gap
  content.width = viewport.width
  content.height = math.max(0, count * stride - metrics.row_gap)
  scroll = math.max(0, math.min(scroll, content.height - viewport.height))
  content.y = -scroll

  for index = 1, count do
    local row = rows[index]
    row.panel.y = (index - 1) * stride
    row.panel.width = content.width
    row.panel.height = metrics.row_height
    row.name.x = metrics.row_padding
    row.name.y = metrics.row_gap
    row.name.width = math.max(0, content.width - 2 * metrics.row_padding)
    row.detail.x = metrics.row_padding
    row.detail.y = metrics.detail_top
    row.detail.width = row.name.width
  end
end

local function layout()
  local width, height = ui.surface.width, ui.surface.height
  local inner_width = math.max(0, width - 2 * metrics.padding)
  background.width, background.height = width, height
  title.x, title.y = metrics.padding, metrics.padding
  heading.x = metrics.padding
  heading.y = title.y + title.implicitHeight + metrics.row_gap
  viewport.x, viewport.y = metrics.padding, metrics.list_top
  viewport.width = inner_width
  viewport.height = math.max(0, height - metrics.list_top - metrics.footer_height)
  status.x = metrics.padding
  status.y = math.max(0, height - metrics.padding - status.implicitHeight)
  status.width = inner_width
  arrange()
end

-- Only this display's workspaces, in the order of their Spaces; the one it shows is selected.
local function update()
  local workspaces = {}

  for _, workspace in ipairs(state.workspaces) do
    workspaces[workspace.id] = workspace
  end

  count = 0

  for _, space in ipairs(displays.workspaces(desktop_state, displays.of(ui.surface))) do
    local workspace = workspaces[space.workspace]

    if workspace then
      count = count + 1
      local row = rows[count] or make_row()
      rows[count] = row
      row.space = space.id
      row.selected = space.visible
      row.name.text = workspace.name
      row.detail.text =
        string.format("%d %s", workspace.tab_count, workspace.tab_count == 1 and "tab" or "tabs")
      row.panel.visible = true
      paint(row)
    end
  end

  heading.text = string.format("WORKSPACES · %d", count)

  for index = count + 1, #rows do
    rows[index].panel.visible = false
    rows[index].space = nil
    rows[index].hovered = false
  end

  local error = state.error or desktop_state.error
  status.color = error and colors.error or colors.muted
  status.text = error
    or (not state.connected and "Connecting to runtime…")
    or (not desktop_state.available and "Waiting for macOS Spaces…")
    or (count == 0 and "No workspaces")
    or "Runtime connected"
  layout()
end

ui.on(viewport, "scroll", function(event)
  local delta = event.pixel_delta.y

  if delta == 0 then
    delta = event.angle_delta.y / metrics.wheel_step * metrics.row_height
  end

  scroll = scroll - delta
  arrange()
  event:stop_propagation()
end)

runtime.on_change(function(next_state)
  state = next_state
  update()
end)

desktop.on_change(function(next_state, changes)
  desktop_state = next_state
  -- Displays alone change nothing the sidebar shows.
  if changes.focus or changes.spaces or changes.operation or changes.status then
    update()
  end
end)

ui.on(ui.surface, "resize", layout)
ui.on(ui.surface, "screen_changed", update)
update()
