-- Run with LuaJIT from services/desktop-mode: luajit tests/wallpaper.lua
local ui_directory = arg[1] or "ui"
local bundled_image = "ghostwire-neon-skyline.png"
local wallpapers = { [bundled_image] = "/usr/share/telar/wallpapers/" .. bundled_image }

local function render(options, image)
  local background, wallpaper, resize
  local surface = { options = options, width = 1280, height = 720 }
  local ui = {
    surface = surface,
    create = function(_, _, settings)
      background = settings
      return settings
    end,
    image = function(settings)
      wallpaper = settings
      return settings
    end,
    on = function(_, event, callback)
      assert(event == "resize")
      resize = callback
    end,
  }
  local modules = {
    ["telar.ui"] = ui,
    ["telar.fs"] = {
      home_dir = "/home/user",
      config_dir = "/home/user/.config/telar",
      find_wallpaper = function(name)
        assert(not name:find("/", 1, true))
        return wallpapers[name]
      end,
    },
    ["telar.theme"] = { colors = { ground = "#211b2f" }, wallpaper = { image = image } },
  }
  local environment = setmetatable({
    require = function(name)
      return assert(modules[name], name)
    end,
  }, { __index = _G })
  setfenv(assert(loadfile(ui_directory .. "/wallpaper/init.lua")), environment)()

  assert(background.color == "#211b2f")
  assert(background.width == surface.width and background.height == surface.height)

  if wallpaper then
    assert(wallpaper.parent == background)
    assert(wallpaper.asynchronous)
    assert(wallpaper.width == surface.width and wallpaper.height == surface.height)
  end

  surface.width, surface.height = 1920, 1080
  resize()
  assert(background.width == 1920 and background.height == 1080)

  if wallpaper then
    assert(wallpaper.width == 1920 and wallpaper.height == 1080)
  end

  return wallpaper
end

local wallpaper = render({}, bundled_image)
assert(wallpaper.source == "file:///usr/share/telar/wallpapers/" .. bundled_image)
-- A theme's wallpaper that no directory holds leaves the ground color.
assert(render({}, "missing.png") == nil)
-- A path or URL in the theme is used as it is.
assert(render({}, "/srv/wall.png").source == "file:///srv/wall.png")
assert(wallpaper.fillMode == "PreserveAspectCrop")
assert(render({ image = "" }, bundled_image) == nil)
assert(render({}, "") == nil)
assert(
  render({ image = "/tmp/My wallpaper.png" }, bundled_image).source
    == "file:///tmp/My%20wallpaper.png"
)
assert(
  render({ image = "~/wallpaper.png" }, bundled_image).source == "file:///home/user/wallpaper.png"
)
assert(
  render({ image = "wallpaper.png" }, bundled_image).source
    == "file:///home/user/.config/telar/wallpaper.png"
)
assert(
  render({ image = ":/telar/wallpapers/custom.png" }, bundled_image).source
    == "qrc:/telar/wallpapers/custom.png"
)
assert(
  render({ image = "https://example.com/wallpaper.png" }, bundled_image).source
    == "https://example.com/wallpaper.png"
)
assert(render({ fit = "contain" }, bundled_image).fillMode == "PreserveAspectFit")
assert(render({ fit = "center" }, bundled_image).fillMode == "Pad")
assert(render({ fit = "stretch" }, bundled_image).fillMode == "Stretch")
assert(not pcall(render, { fit = "unknown" }, bundled_image))

print("Desktop wallpaper: theme names, overrides, paths, fitting and resize passed")
