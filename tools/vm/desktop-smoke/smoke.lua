-- Diagnostic configuration for the QEMU smoke test, using the public Lua API.
require("desktop")
local fs = require("telar.fs")
local desktop = require("telar.desktop")
local runtime = require("telar.runtime")
local workbench = require("telar.workbench")
local shortcuts = require("telar.shortcuts")

local function quote(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return string.format("\\u%04x", string.byte(char))
  end) .. '"'
end

local function json(value)
  if type(value) == "string" then return quote(value) end
  if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
  if type(value) ~= "table" then return "null" end
  local result = {}
  if #value > 0 then
    for _, item in ipairs(value) do result[#result + 1] = json(item) end
    return "[" .. table.concat(result, ",") .. "]"
  end
  for key, item in pairs(value) do result[#result + 1] = quote(tostring(key)) .. ":" .. json(item) end
  return "{" .. table.concat(result, ",") .. "}"
end

local pending = {}
local writing = {}
local function record(name, value)
  pending[name] = json(value)
  if writing[name] then return end
  local function flush()
    local data = pending[name]
    pending[name] = nil
    writing[name] = true
    fs.write_file(name .. ".json", data, function(error)
      assert(not error, error)
      writing[name] = false
      if pending[name] then flush() end
    end)
  end
  flush()
end

desktop.on_change(function(state) record("desktop", state) end)
runtime.on_change(function(state) record("runtime", state) end)
workbench.on_change(function() record("workbench", workbench.state()) end)

-- Records compositor discovery even for a client excluded by a layout rule.
shortcuts.bind_global("ctrl+alt+w", function()
  record("windows", workbench.command("windows"))
end)
