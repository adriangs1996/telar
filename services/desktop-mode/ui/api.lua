local core = _telar_ui
_telar_ui = nil
local io_core = _telar_io
_telar_io = nil

local ui = {}
local fs = { config_dir = io_core.config_dir, home_dir = io_core.home_dir }
local net = {}
local runtime = {}
local desktop = {}
local shortcuts = {}
local workbench = {}
telar = {
  ui = ui,
  fs = fs,
  net = net,
  runtime = runtime,
  desktop = desktop,
  shortcuts = shortcuts,
  workbench = workbench,
}

workbench.state = core.workbench_state

function workbench.command(action, options)
  return core.workbench_command(action, options or {})
end

function workbench.on_change(callback)
  assert(type(callback) == "function", "workbench.on_change expects a callback")
  local id = core.workbench_on(nil, nil, callback)
  return function()
    if id then
      core.workbench_off(id)
      id = nil
    end
  end
end

shortcuts.set_prefix = core.shortcut_prefix
shortcuts.state = core.shortcut_state

local function bind_shortcut(keys, global, callback)
  assert(type(keys) == "table", "Shortcut keys must be an array")
  assert(type(callback) == "function", "Shortcut requires a callback")
  local identifier = core.shortcut_bind(keys, global, callback)

  return function()
    if identifier then
      core.shortcut_unbind(identifier)
      identifier = nil
    end
  end
end

function shortcuts.bind(keys, callback)
  return bind_shortcut(keys, false, callback)
end

function shortcuts.bind_global(key, callback)
  assert(type(key) == "string", "Global shortcut must be one modified chord")
  return bind_shortcut({ key }, true, callback)
end

runtime.state = core.runtime_state
runtime.agents = core.runtime_agents
runtime.select_tab = core.runtime_select
runtime.move_tab = core.runtime_move
runtime.create_workspace = core.runtime_create_workspace
desktop.state = core.desktop_state
desktop.activate_space = core.desktop_activate
desktop.bind_space = core.desktop_bind
desktop.remove_space = core.desktop_remove

function desktop.configure_surface(name, settings)
  assert(type(name) == "string", "configure_surface expects a surface name")
  assert(type(settings) == "table", "configure_surface expects a settings table")
  core.configure_surface(name, settings)
end

function desktop.create_space(options)
  assert(
    options == nil or type(options) == "table",
    "desktop.create_space expects an options table"
  )
  return core.desktop_create(options or {})
end

function desktop.on_change(callback)
  assert(type(callback) == "function", "desktop.on_change expects a callback")
  local identifier = core.desktop_on(nil, nil, callback)

  return function()
    if identifier then
      core.runtime_off(identifier)
      identifier = nil
    end
  end
end

function runtime.on_agents(callback)
  assert(type(callback) == "function", "runtime.on_agents expects a callback")
  local identifier = core.agents_on(nil, nil, callback)

  return function()
    if identifier then
      core.runtime_off(identifier)
      identifier = nil
    end
  end
end

function runtime.on_change(callback)
  assert(type(callback) == "function", "runtime.on_change expects a callback")
  local identifier = core.runtime_on(nil, nil, callback)

  return function()
    if identifier then
      core.runtime_off(identifier)
      identifier = nil
    end
  end
end

local function operation(fn, ...)
  local identifier = fn(...)

  return function()
    if identifier then
      io_core.cancel(identifier)
      identifier = nil
    end
  end
end

function fs.read_file(path, callback)
  return operation(io_core.read_file, path, callback)
end

function fs.write_file(path, contents, callback)
  return operation(io_core.write_file, path, contents, callback)
end

function fs.list_dir(path, callback)
  return operation(io_core.list_dir, path, callback)
end

function fs.watch(path, callback)
  return operation(io_core.watch, path, callback)
end

function net.request(options, callback)
  return operation(io_core.request, options, callback)
end

package = { path = io_core.module_path, loaded = {}, preload = {} }
local loading = {}

function require(name)
  assert(type(name) == "string" and name ~= "", "require expects a module name")

  if package.loaded[name] then
    return package.loaded[name]
  end

  if loading[name] then
    error("Circular module dependency: " .. name, 2)
  end

  local loader = package.preload[name]

  if not loader then
    local module = io_core.module_source(name, package.path)
    local message
    loader, message = loadstring(module.source, "@" .. module.path)

    if not loader then
      error(message, 2)
    end

    setfenv(loader, _G)
  end

  loading[name] = true
  local ok, result = xpcall(function()
    return loader(name)
  end, io_core.traceback)
  loading[name] = nil

  if not ok then
    error(result, 2)
  end

  if result ~= nil then
    package.loaded[name] = result
  elseif package.loaded[name] == nil then
    package.loaded[name] = true
  end

  return package.loaded[name]
end

package.loaded["_G"] = _G
package.loaded["package"] = package
package.loaded["table"] = table
package.loaded["string"] = string
package.loaded["math"] = math
package.loaded["jit"] = jit
package.loaded["telar"] = telar
package.loaded["telar.ui"] = ui
package.loaded["telar.fs"] = fs
package.loaded["telar.net"] = net
package.loaded["telar.runtime"] = runtime
package.loaded["telar.desktop"] = desktop
package.loaded["telar.shortcuts"] = shortcuts
package.loaded["telar.workbench"] = workbench

local default_theme = "dark"

local function copy(value)
  if type(value) ~= "table" then
    return value
  end

  local result = {}

  for key, element in pairs(value) do
    result[key] = copy(element)
  end

  return result
end

-- The default theme names every token, so an override must name one of them and keep its type.
-- A token whose default is a color takes only #RRGGBB or #AARRGGBB.
local function apply_theme(into, overrides, path)
  for key, value in pairs(overrides) do
    if type(key) ~= "string" then
      error("Theme keys must be names, found " .. tostring(key) .. " in " .. path, 3)
    end

    local name = path == "" and key or (path .. "." .. key)
    local current = into[key]

    if current == nil then
      error("Unknown theme token " .. name, 3)
    end

    if type(value) ~= type(current) then
      error("Theme token " .. name .. " must be a " .. type(current), 3)
    end

    if type(current) == "table" then
      apply_theme(current, value, name)
    else
      local color = type(current) == "string" and current:sub(1, 1) == "#"

      if color and not (value:match("^#%x+$") and (#value == 7 or #value == 9)) then
        error("Theme token " .. name .. " must be a #RRGGBB or #AARRGGBB color", 3)
      end

      into[key] = value
    end
  end
end

-- `preset` names a module under themes/, so a theme can live in the configuration directory as
-- themes/<name>.lua and return the tokens it changes. The other fields override single tokens.
local function resolve_theme(settings)
  assert(type(settings) == "table", "desktop.theme expects a settings table")
  local preset = settings.preset or default_theme
  assert(
    type(preset) == "string" and preset:match("^[%w_-]+$"),
    "Theme preset must be a name of letters, digits, - or _"
  )

  local resolved = copy(require("themes." .. default_theme))

  if preset ~= default_theme then
    local tokens = require("themes." .. preset)
    assert(type(tokens) == "table", "Theme preset " .. preset .. " must return a table")
    apply_theme(resolved, tokens, "")
  end

  local overrides = copy(settings)
  overrides.preset = nil
  apply_theme(resolved, overrides, "")

  return resolved
end

function desktop.theme(settings)
  local resolved = resolve_theme(settings or {})
  core.configure_theme(resolved)
  telar.theme = resolved
  package.loaded["telar.theme"] = resolved

  return resolved
end

ui.create = core.create
ui.get = core.get
ui.set = core.set
ui.append = core.append
ui.animate = core.animate
ui.focus = core.focus
ui.input_method = core.input_method

local event_methods = {}

function event_methods:accept(action)
  self.accepted = true
  self.drop_action = action
end

function event_methods:stop_propagation()
  self._stopped = true
end

function event_methods:capture_pointer()
  self._capture = true
  self.accepted = true
end

function event_methods:release_pointer()
  self._release_capture = true
end

function event_methods:focus()
  self._focus = true
end

function ui.on(target, name, callback)
  assert(type(callback) == "function", "ui.on expects a callback")

  if target == ui.surface then
    target = core.root
  end

  local identifier = core.on(target, name, function(event)
    setmetatable(event, { __index = event_methods })
    callback(event)
    return event
  end)

  return function()
    if identifier then
      core.off(identifier)
      identifier = nil
    end
  end
end

local surface_config = core.root and core.surface_config()

-- Surfaces receive the theme desktop.lua resolved; desktop.lua starts from the default one.
if surface_config then
  telar.theme = surface_config.theme
  package.loaded["telar.theme"] = surface_config.theme
else
  desktop.theme()
end

local text_defaults = {}

if telar.theme.fonts.ui ~= "" then
  text_defaults["font.family"] = telar.theme.fonts.ui
end

ui.surface = setmetatable({}, {
  __index = function(_, name)
    assert(surface_config, "desktop.lua has no surface; configure surfaces through telar.desktop")

    if name == "options" or name == "module" or name == "name" then
      return surface_config[name]
    end

    if name == "root" then
      return core.root
    end

    if name == "width" or name == "height" then
      return core.root[name]
    end

    return core.surface_state()[name]
  end,
  __newindex = function()
    error("Surface geometry is managed by the native backend")
  end,
})

local function item(kind, options, defaults)
  options = options or {}
  local properties = {}

  for name, value in pairs(defaults or {}) do
    properties[name] = value
  end

  for name, value in pairs(options) do
    if name ~= "parent" then
      properties[name] = value
    end
  end

  return core.create("QtQuick", kind, properties, options.parent)
end

function ui.item(options)
  return item("Item", options)
end

function ui.text(options)
  return item("Text", options, text_defaults)
end

function ui.image(options)
  return item("Image", options)
end

-- A path is a composition of Qt objects; aliases keep its paint editable in Lua.
function ui.path(options)
  assert(type(options) == "table", "ui.path requires an options table")
  assert(type(options.path) == "string", "ui.path requires an SVG path string")

  local properties = { containsMode = "FillContains", fillMode = "Stretch" }

  for name, value in pairs(options) do
    if
      name ~= "parent"
      and name ~= "path"
      and name ~= "fill"
      and name ~= "stroke"
      and name ~= "stroke_width"
    then
      properties[name] = value
    end
  end

  local shape = core.create("QtQuick.Shapes", "Shape", properties, options.parent)
  local paint = core.create("QtQuick.Shapes", "ShapePath", {
    fillColor = options.fill or "transparent",
    strokeColor = options.stroke or "transparent",
    strokeWidth = options.stroke_width or 1,
  }, shape)
  local geometry = core.create("QtQuick", "PathSvg", { path = options.path }, paint)

  core.append(paint, "pathElements", geometry)
  core.append(shape, "data", paint)
  core.alias(shape, "fill", paint, "fillColor")
  core.alias(shape, "stroke", paint, "strokeColor")
  core.alias(shape, "stroke_width", paint, "strokeWidth")
  core.alias(shape, "path", geometry, "path")

  return shape
end
