local telar = require("telar")

local command_fields = {
  Bash = "command",
  shell = "command",
  exec_command = "cmd",
}

local function decode(text)
  if type(text) ~= "string" or text == "" then return nil end

  local ok, value = pcall(telar.json.decode, text)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function command_from(name, input)
  local field = command_fields[name]
  if field == nil or type(input) ~= "table" then return nil end

  local command = input[field]
  if type(command) ~= "string" or command == "" then return nil end
  return command
end

local function add_command(effects, seen, exchange, provider, name, tool_call_id, input)
  if #effects >= 15 then return end

  local command = command_from(name, input)
  if command == nil then return end

  local identity = type(tool_call_id) == "string" and tool_call_id or ""
  if identity ~= "" and seen[identity] then return end
  if identity ~= "" then seen[identity] = true end

  local duration = exchange.finished_at_ms - exchange.started_at_ms
  if duration < 0 then duration = 0 end
  effects[#effects + 1] = telar.effect.history.record_command({
    command = command,
    cwd = "",
    provider = provider,
    tool_call_id = identity,
    exit_code = 0,
    started_at_ms = exchange.started_at_ms,
    duration_ms = duration,
    redact = true,
  })
end

local function each_sse_event(body, callback)
  for line in string.gmatch(body, "[^\r\n]+") do
    local data = string.match(line, "^data:%s?(.*)$")
    if data ~= nil and data ~= "[DONE]" then
      local event = decode(data)
      if event ~= nil then callback(event) end
    end
  end
end

local function anthropic_commands(exchange, body, effects, seen)
  local document = decode(body)
  if document ~= nil and type(document.content) == "table" then
    for _, block in ipairs(document.content) do
      if type(block) == "table" and block.type == "tool_use" then
        add_command(effects, seen, exchange, "claude", block.name, block.id, block.input)
      end
    end
    return
  end

  local calls = {}
  each_sse_event(body, function(event)
    if event.type == "content_block_start" and type(event.content_block) == "table" and
        event.content_block.type == "tool_use" then
      local index = event.index
      if type(index) == "number" then
        calls[index] = {
          id = event.content_block.id,
          name = event.content_block.name,
          input = event.content_block.input,
          fragments = {},
        }
      end
    elseif event.type == "content_block_delta" and type(event.delta) == "table" and
        event.delta.type == "input_json_delta" then
      local call = type(event.index) == "number" and calls[event.index] or nil
      if call ~= nil and type(event.delta.partial_json) == "string" then
        call.fragments[#call.fragments + 1] = event.delta.partial_json
      end
    elseif event.type == "content_block_stop" then
      local index = event.index
      local call = type(index) == "number" and calls[index] or nil
      if call ~= nil then
        local input = decode(table.concat(call.fragments)) or call.input
        add_command(effects, seen, exchange, "claude", call.name, call.id, input)
        calls[index] = nil
      end
    end
  end)
end

local function openai_commands(exchange, body, effects, seen)
  local document = decode(body)
  if document ~= nil and type(document.output) == "table" then
    for _, item in ipairs(document.output) do
      if type(item) == "table" and item.type == "function_call" then
        add_command(
          effects,
          seen,
          exchange,
          "codex",
          item.name,
          item.call_id or item.id,
          decode(item.arguments)
        )
      end
    end
    return
  end

  local calls = {}
  each_sse_event(body, function(event)
    if event.type == "response.output_item.added" and type(event.item) == "table" and
        event.item.type == "function_call" then
      local item_id = event.item.id
      if type(item_id) == "string" then
        local fragments = {}
        if type(event.item.arguments) == "string" then fragments[1] = event.item.arguments end
        calls[item_id] = {
          id = event.item.call_id or item_id,
          name = event.item.name,
          fragments = fragments,
        }
      end
    elseif event.type == "response.function_call_arguments.delta" then
      local call = type(event.item_id) == "string" and calls[event.item_id] or nil
      if call ~= nil and type(event.delta) == "string" then
        call.fragments[#call.fragments + 1] = event.delta
      end
    elseif event.type == "response.function_call_arguments.done" then
      local item_id = event.item_id
      local call = type(item_id) == "string" and calls[item_id] or nil
      call = call or {
        id = event.call_id or event.item_id,
        name = event.name,
        fragments = {},
      }
      local arguments = type(event.arguments) == "string" and event.arguments or table.concat(call.fragments)
      add_command(effects, seen, exchange, "codex", call.name, call.id, decode(arguments))
      if type(item_id) == "string" then calls[item_id] = nil end
    end
  end)
end

return {
  on_exchange = function(exchange)
    if exchange.response == nil or exchange.response.body_truncated or
        not exchange.response.body_decoded then return {} end

    local effects = {}
    local seen = {}
    if exchange.dialect == "anthropic_messages" then
      anthropic_commands(exchange, exchange.response.body, effects, seen)
    elseif exchange.dialect == "openai_responses" then
      openai_commands(exchange, exchange.response.body, effects, seen)
    end

    if #effects ~= 0 and #effects < 16 then
      effects[#effects + 1] = telar.effect.notification({
        level = "info",
        title = "Agent command recorded",
        message = "Recorded " .. tostring(#effects) .. " command(s) from " .. exchange.dialect,
      })
    end
    return effects
  end,
}
