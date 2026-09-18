local telar = require("telar")

return telar.config({
  api_version = 2,
  theme = "shade",
  gui = {
    window = {
      titlebar = true, -- Defaults to false on macOS and true on Linux.
      background_opacity = 0.95,
      background_blur = 20, -- 0 disables; Wayland controls the positive intensity.
      padding = { x = 8, y = 8 },
    },
    font = {
      family = "JetBrains Mono", -- Bundled; an installed family name also works.
      size = 15,
      line_height = 1.15,
      letter_spacing = 0,
      thicken = false, -- macOS optical weight; independent of bold text.
      thicken_strength = 255,
    },
    cursor = {
      style = "block",
      blink = true,
      blink_interval_ms = 600,
    },
    chrome = {
      scale = 1, -- 0.5..2; chrome text only, the terminal grid stays.
    },
    sidebar = {
      width = 284, -- 220..480 logical px; the grid starts after it and an 8 px gap.
    },
  },
  profiles = {
    presentation = { gui = { font = { size = 20, line_height = 1.3 } } },
  },
})
