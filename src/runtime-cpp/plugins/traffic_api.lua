return function(traffic, io_core)
  local function operation(fn, ...)
    local identifier = fn(...)
    return function()
      if identifier then io_core.cancel(identifier); identifier = nil end
    end
  end

  function traffic.subscribe(options, callback)
    assert(type(options) == "table", "traffic.subscribe expects options")
    assert(type(callback) == "function", "traffic.subscribe expects a callback")
    return operation(io_core.traffic_subscribe, options, callback)
  end

  local function traffic_control(action, options, callback)
    assert(type(callback) == "function", "Traffic control expects a callback")
    local request = {action = action}
    for name, value in pairs(options or {}) do
      assert(name ~= "action", "Traffic operation cannot be overridden")
      request[name] = value
    end
    return operation(io_core.traffic_control, request, callback)
  end

  function traffic.status(callback)
    return traffic_control("status", nil, callback)
  end

  traffic.capture = {}
  function traffic.capture.start(callback)
    return traffic_control("capture.start", nil, callback)
  end
  function traffic.capture.stop(callback)
    return traffic_control("capture.stop", nil, callback)
  end

  traffic.redirect = {}
  function traffic.redirect.start(options, callback)
    assert(type(options) == "table", "traffic.redirect.start expects options")
    return traffic_control("redirect.start", options, callback)
  end
  function traffic.redirect.stop(callback)
    return traffic_control("redirect.stop", nil, callback)
  end

  traffic.ca = {}
  function traffic.ca.certificate(callback)
    return traffic_control("ca.certificate", nil, callback)
  end
  function traffic.ca.install(callback)
    return traffic_control("ca.install", nil, callback)
  end
  function traffic.ca.uninstall(callback)
    return traffic_control("ca.uninstall", nil, callback)
  end
  function traffic.ca.rotate(callback)
    return traffic_control("ca.rotate", nil, callback)
  end

  traffic.recordings = {}
  function traffic.recordings.list(callback)
    return traffic_control("recording.list", nil, callback)
  end
  for _, action in ipairs({"start", "query", "stop", "remove", "export"}) do
    traffic.recordings[action] = function(options, callback)
      assert(type(options) == "table", "Traffic recording expects options")
      return traffic_control("recording." .. action, options, callback)
    end
  end

  function traffic.intercept(options, callback)
    assert(type(options) == "table", "traffic.intercept expects options")
    assert(type(callback) == "function", "traffic.intercept expects a callback")
    local identifier
    identifier = io_core.traffic_intercept(options, function(err, event)
      if event and (event.kind == "intercept.request" or event.kind == "http.intercept.request") then
        local answered = false
        event.respond = function(decision)
          if answered or not identifier then return false end
          if event.kind == "http.intercept.request" and decision.action == "replace" then
            local message = {}
            for name, value in pairs(event.message) do message[name] = value end
            for name, value in pairs(decision) do
              assert(name == "action" or name == "body" or name == "headers" or name == "trailers" or name == "method" or name == "target" or name == "status" or name == "reason" or name == "scheme" or name == "authority", "Unknown HTTP decision field: " .. name)
              if name ~= "action" then message[name] = value end
            end
            decision = {action = "replace", message = message}
          end
          local accepted = io_core.traffic_decide(identifier, event.ticket, decision)
          answered = true
          return accepted
        end
      end
      local decision = callback(err, event)
      if decision and event and event.respond then event.respond(decision) end
    end)
    return function()
      if identifier then io_core.cancel(identifier); identifier = nil end
    end
  end

end
