local ui = require("telar.ui")
local fs = require("telar.fs")
local theme = require("telar.theme")
local options = ui.surface.options

local fill_modes = {
  cover = "PreserveAspectCrop",
  contain = "PreserveAspectFit",
  center = "Pad",
  stretch = "Stretch",
}

local fill_mode = fill_modes[options.fit or "cover"]
assert(fill_mode, "Wallpaper fit must be cover, contain, center or stretch")

local function image_source(path)
  assert(type(path) == "string", "Wallpaper image must be a path or URL")

  if path:match("^%a[%w+.-]*:") then
    return path
  end

  if path:sub(1, 2) == ":/" then
    return "qrc" .. path
  end

  if path:sub(1, 2) == "~/" then
    path = fs.home_dir .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    path = fs.config_dir .. "/" .. path
  end

  local encoded = path:gsub("([^%w/._~-])", function(byte)
    return string.format("%%%02X", string.byte(byte))
  end)

  return "file://" .. encoded
end

local background = ui.create("QtQuick", "Rectangle", {
  color = theme.colors.ground,
  clip = true,
})

local image

if options.image and options.image ~= "" then
  image = ui.image({
    parent = background,
    source = image_source(options.image),
    fillMode = fill_mode,
    asynchronous = true,
  })
end

local function layout()
  local width, height = ui.surface.width, ui.surface.height
  background.width = width
  background.height = height

  if image then
    image.width = width
    image.height = height
  end
end

ui.on(ui.surface, "resize", layout)
layout()
