-- The focus ring: a border around another application's window while it has the focus, drawn in
-- the gap around it, as a pane draws its own border. The surface is the window's frame grown by
-- the ring's thickness on every side, and lets every click through.
local ui = require("telar.ui")
local theme = require("telar.theme")

local options = ui.surface.options
local thickness = options.thickness or 2

local ring = ui.create("QtQuick", "Rectangle", {
  color = "transparent",
  radius = theme.radius.large + thickness,
  ["border.width"] = thickness,
  ["border.color"] = theme.colors.accent,
})

local function layout()
  ring.width = ui.surface.width
  ring.height = ui.surface.height
end

ui.on(ui.surface, "resize", layout)
layout()
