-- The backstage switcher: the windows sent out of every layout, each its application's icon over
-- its title, shown over this display while the user cycles through them, as with Cmd+Tab.
local ui = require("telar.ui")
local workbench = require("telar.workbench")
local theme = require("telar.theme")
local displays = require("displays")

local colors = theme.colors

local metrics = {
  padding = 16,
  cell = 120,
  icon = 72,
  gap = 8,
  title_size = 12,
  title_height = 32,
}

local panel = ui.create("QtQuick", "Rectangle", {
  color = colors.chrome,
  radius = theme.radius.large,
  ["border.color"] = colors.border,
  ["border.width"] = 1,
  visible = false,
})

-- Cells are kept and reused, so cycling never creates Qt objects.
local cells = {}

local function cell(index)
  if cells[index] then
    return cells[index]
  end

  local frame = ui.create("QtQuick", "Rectangle", {
    width = metrics.cell,
    height = metrics.cell,
    radius = theme.radius.medium,
  }, panel)

  cells[index] = {
    frame = frame,
    icon = ui.image({
      parent = frame,
      x = (metrics.cell - metrics.icon) / 2,
      y = metrics.gap,
      width = metrics.icon,
      height = metrics.icon,
      -- Twice the drawn size, so the icon stays sharp on a Retina display.
      ["sourceSize.width"] = metrics.icon * 2,
      ["sourceSize.height"] = metrics.icon * 2,
      smooth = true,
    }),
    title = ui.text({
      parent = frame,
      x = metrics.gap,
      y = metrics.gap + metrics.icon + 4,
      width = metrics.cell - 2 * metrics.gap,
      height = metrics.title_height,
      textFormat = "PlainText",
      elide = "ElideRight",
      wrapMode = "WordWrap",
      maximumLineCount = 2,
      horizontalAlignment = "AlignHCenter",
      color = colors.text,
      ["font.pixelSize"] = metrics.title_size,
    }),
  }

  return cells[index]
end

local function update()
  local state = workbench.state()
  local switcher = state.switcher
  local windows = state.backstage or {}

  if not switcher or switcher.display ~= displays.of(ui.surface) or #windows == 0 then
    panel.visible = false
    return
  end

  -- As many columns as fit the display, then rows.
  local step = metrics.cell + metrics.gap
  local fit = math.floor((ui.surface.width - 2 * metrics.padding + metrics.gap) / step)
  local columns = math.max(1, math.min(#windows, fit))
  local rows = math.ceil(#windows / columns)

  for index, window in ipairs(windows) do
    local entry = cell(index)
    local selected = window.window == switcher.window
    local column = (index - 1) % columns
    local row = math.floor((index - 1) / columns)

    entry.frame.visible = true
    entry.frame.x = metrics.padding + column * step
    entry.frame.y = metrics.padding + row * step
    entry.frame.color = selected and colors.selected or "transparent"
    entry.frame["border.color"] = selected and colors.accent or "transparent"
    entry.frame["border.width"] = selected and 1 or 0
    entry.icon.source = "image://app-icon/" .. window.pid
    entry.title.text = window.title ~= "" and window.title or window.application
  end

  for index = #windows + 1, #cells do
    cells[index].frame.visible = false
  end

  panel.width = 2 * metrics.padding + columns * step - metrics.gap
  panel.height = 2 * metrics.padding + rows * step - metrics.gap
  panel.x = math.floor((ui.surface.width - panel.width) / 2)
  panel.y = math.floor((ui.surface.height - panel.height) / 2)
  panel.visible = true
end

workbench.on_change(update)
ui.on(ui.surface, "resize", update)
ui.on(ui.surface, "screen_changed", update)
update()
