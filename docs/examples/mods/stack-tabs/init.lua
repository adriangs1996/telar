-- Tabs whose panes stack as tilted application tiles. The focused pane's tile
-- lifts and comes to the front, eased on the window clock rather than in Lua.
local telar = require("telar")
local ui = telar.ui

local M = {}

local function cards(tab)
  local stack = { width = 34, height = 22 }
  -- Draw the focused pane last so it sits on top.
  local ordered = {}
  for _, pane in ipairs(tab.panes) do
    if not pane.focused then ordered[#ordered + 1] = pane end
  end
  for _, pane in ipairs(tab.panes) do
    if pane.focused then ordered[#ordered + 1] = pane end
  end

  for depth, pane in ipairs(ordered) do
    local front = depth == #ordered
    stack[#stack + 1] = ui.tile({
      id = pane.key,
      program = pane.program,
      size = 18,
      x = front and 0 or (#ordered - depth) * 7,
      y = front and -2 or 0,
      rotation = front and -8 or -3,
      scale = front and 1.06 or 0.93,
      z = depth,
      -- A ring drawn around the tile: the padding leaves it room to show.
      padding = pane.attention and 2 or 0,
      border = pane.attention and { color = "yellow", width = 2 } or nil,
      transition = 220,
    })
  end

  return ui.stack(stack)
end

function M.tab(ctx, tab)
  local row = {
    width = 200, gap = 8, padding = { 0, 12 }, align = "center",
    cards(tab),
    ui.label({ text = tab.title, bold = tab.selected, grow = 1 }),
  }
  if tab.path ~= "" then
    row[#row + 1] = ui.label({ text = tab.path, tone = "muted", size = "small", max_width = 70 })
  end
  if tab.attention then
    row[#row + 1] = ui.badge({ text = "!", tone = "warning" })
  end
  return ui.row(row)
end

return M
