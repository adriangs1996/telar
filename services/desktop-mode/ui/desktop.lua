local desktop = require("telar.desktop")

require("shortcuts")()

local colors = { background = "#1b1723", accent = "#c4a7e7" }

desktop.configure_surface("topbar", {
  module = "topbar",
  options = { colors = colors },
})

desktop.configure_surface("sidebar", {
  module = "sidebar",
  options = { colors = colors },
})
