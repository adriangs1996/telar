local shortcuts = require("telar.shortcuts")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local workbench = require("telar.workbench")

local function active_index(state)
  for index, tab in ipairs(state.tabs) do
    if tab.id == state.active_tab then
      return index
    end
  end
end

local function select_tab(index)
  local state = runtime.state()
  local tab = state.tabs[index]

  if state.connected and state.workspace and tab then
    runtime.select_tab(tab.id)
  end
end

local function step_tab(offset, move)
  local state = runtime.state()
  local index = active_index(state)

  if not state.connected or not state.workspace or not index or #state.tabs < 2 then
    return
  end

  if move then
    local neighbor = state.tabs[index + offset]

    if neighbor then
      runtime.move_tab(state.active_tab, { [offset > 0 and "after" or "before"] = neighbor.id })
    end
  else
    runtime.select_tab(state.tabs[(index - 1 + offset) % #state.tabs + 1].id)
  end
end

local function step_space(offset)
  local state = desktop.state()
  local current

  for _, space in ipairs(state.spaces) do
    if space.id == state.focused_space then
      current = space
      break
    end
  end

  if not current or state.pending_space then
    return
  end

  local spaces = {}
  local index

  for _, space in ipairs(state.spaces) do
    if space.display == current.display and not space.fullscreen then
      spaces[#spaces + 1] = space

      if space.id == current.id then
        index = #spaces
      end
    end
  end

  if index and #spaces > 1 then
    desktop.activate_space(spaces[(index - 1 + offset) % #spaces + 1].id)
  end
end

return function()
  shortcuts.bind({ "%" }, function()
    workbench.command("split", { axis = "horizontal" })
  end)
  shortcuts.bind({ '"' }, function()
    workbench.command("split", { axis = "vertical" })
  end)
  shortcuts.bind({ "x" }, function()
    workbench.command("close")
  end)
  shortcuts.bind({ "z" }, function()
    workbench.command("maximize")
  end)
  shortcuts.bind({ "f" }, function()
    workbench.command("float")
  end)
  shortcuts.bind({ "o" }, function()
    workbench.command("cycle")
  end)
  for _, direction in ipairs({ "left", "right", "up", "down" }) do
    local target = direction
    shortcuts.bind({ direction }, function()
      workbench.command("navigate", { direction = target })
    end)
    shortcuts.bind({ "alt+" .. direction }, function()
      workbench.command("resize", { direction = target })
    end)
  end
  -- Match the GUI's tab bindings. Actions without a desktop implementation stay unbound.
  shortcuts.bind({ "n" }, function()
    step_tab(1, false)
  end)
  shortcuts.bind({ "p" }, function()
    step_tab(-1, false)
  end)
  shortcuts.bind({ "," }, function()
    step_tab(-1, true)
  end)
  shortcuts.bind({ "." }, function()
    step_tab(1, true)
  end)

  for index = 1, 9 do
    local tab_index = index
    shortcuts.bind({ tostring(index) }, function()
      select_tab(tab_index)
    end)
  end

  shortcuts.bind_global("ctrl+left", function()
    step_space(-1)
  end)
  shortcuts.bind_global("ctrl+right", function()
    step_space(1)
  end)
end
