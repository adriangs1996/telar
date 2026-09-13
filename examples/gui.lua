local telar = require("telar")

return telar.config({
  api_version = 2,
  theme = "vesper",
  gui = {
    window = {
      titlebar = true, -- Set false to hide the native titlebar.
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
  },
  profiles = {
    presentation = { gui = { font = { size = 20, line_height = 1.3 } } },
  },
})
