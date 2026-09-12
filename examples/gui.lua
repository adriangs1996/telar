local telar = require("telar")

return telar.config({
  api_version = 2,
  theme = "vesper",
  gui = {
    font = {
      family = "JetBrains Mono", -- Bundled; an installed family name also works.
      size = 15,
      line_height = 1.15,
      letter_spacing = 0,
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
