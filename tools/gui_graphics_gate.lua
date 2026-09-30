-- The graphics gate's window: no sidebar and no changing metrics, so the
-- latency probe's glyph count moves only with the pane it types into.
local telar = require("telar")

return telar.config({
  api_version = 2,
  client = {
    sidebar = { visible = false },
    bars = { bottom = { center = telar.bar.tabs() } },
  },
})
