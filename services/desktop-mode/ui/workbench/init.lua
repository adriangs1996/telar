local ui = require("telar.ui")
local workbench = require("telar.workbench")
local options = ui.surface.options
local colors = options.colors or {}
local header_height = options.header_height or 28

local background = ui.create("QtQuick", "Rectangle", {
  color = colors.background or "#1b1723",
  radius = 8,
  ["border.width"] = 1,
  ["border.color"] = colors.border or "#393142",
})

local title = ui.text({
  color = colors.foreground or "#cdd6f4",
  textFormat = "PlainText",
  ["font.pixelSize"] = 12,
  x = 12,
  y = 6,
})

local close =
  ui.text({ text = "×", color = colors.foreground or "#cdd6f4", y = 4, ["font.pixelSize"] = 16 })
local header = ui.item({ height = header_height })
local resize = ui.item({ width = 8, height = 8 })
local drag

-- Reads one snapshot: each ui.surface field read builds the whole surface state.
local function update(state)
  background.width = state.width
  background.height = state.height
  header.width = state.width - 32
  close.x = state.width - 24
  resize.x = state.width - 8
  resize.y = state.height - 8
  title.text = state.pane and ("Pane " .. state.pane) or "Telar"
  background["border.color"] = state.focused and (colors.accent or "#c4a7e7")
    or (colors.border or "#393142")
end

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
