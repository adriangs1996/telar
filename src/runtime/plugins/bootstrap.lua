local function effect(kind, options)
  if type(options) ~= "table" then error(kind .. " expects a table") end
  options.__telar_kind = kind
  return options
end

return {
  effect = {
    notification = function(options) return effect("notification", options) end,
  },
  redact = {},
  json = {},
}
