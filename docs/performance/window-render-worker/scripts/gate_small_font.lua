-- The graphics gate's window with a small font, so the grid holds about
-- four times the cells and scene preparation shows its upper cost.
local telar = require("telar")

return telar.config({
  api_version = 2,
  client = {
    sidebar = { visible = false },
    bars = { bottom = { center = telar.bar.tabs() } },
  },
  gui = { font = { size = 8 } },
})
