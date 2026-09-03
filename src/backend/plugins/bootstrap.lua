local function effect(kind, options)
  if type(options) ~= "table" then error(kind .. " expects a table") end
  options.__telar_kind = kind
  return options
end

return {
  effect = {
    history = {
      record_command = function(options) return effect("record_command", options) end,
    },
    agent_evidence = function(options) return effect("agent_evidence", options) end,
    notification = function(options) return effect("notification", options) end,
  },
  redact = {},
  json = {},
}
