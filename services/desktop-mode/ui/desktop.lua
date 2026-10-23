local desktop = require("telar.desktop")

require("shortcuts")()

-- The default theme; pick another with preset = "<name>" (themes/<name>.lua in this directory)
-- and override single tokens, e.g. colors = { accent = "#8FB8FF" }.
desktop.theme({ preset = "cybervenom" })

desktop.configure_surface("wallpaper", {
  module = "wallpaper",
  options = { fit = "cover" },
})

desktop.configure_surface("topbar", {
  module = "topbar",
})

desktop.configure_surface("sidebar", {
  module = "sidebar",
})
