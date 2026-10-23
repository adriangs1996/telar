local shortcuts = require("telar.shortcuts")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local workbench = require("telar.workbench")
local displays = require("displays")

local function active_index(state)
  for index, tab in ipairs(state.tabs) do
    if tab.id == state.active_tab then
      return index
    end
  end
end

-- Exposed so a custom desktop.lua can bind the same actions to its own keys.
local actions = {}

function actions.select_tab(index)
  local state = runtime.state()
  local tab = state.tabs[index]

  if state.connected and state.workspace and tab then
    runtime.select_tab(tab.id)
  end
end

function actions.step_tab(offset, move)
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

function actions.step_space(offset)
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

-- Stops following the workspace the previous create_workspace asked for.
local stop_following

-- Activates the Space of the workspace `request` creates, once the desktop has given it one.
local function follow_created(request)
  local workspace
  local stop_runtime, stop_desktop

  local function stop()
    stop_runtime()
    stop_desktop()
    stop_following = nil
  end

  local function focus()
    local state = desktop.state()

    if not workspace or state.pending_space then
      return
    end

    for _, space in ipairs(state.spaces) do
      if space.workspace == workspace and not space.fullscreen then
        stop()
        desktop.activate_space(space.id)
        return
      end
    end
  end

  stop_runtime = runtime.on_change(function(state)
    local created = state.created

    if workspace or not created or created.request ~= request then
      return
    end

    if not created.workspace then
      stop()
      return
    end

    workspace = created.workspace
    focus()
  end)
  stop_desktop = desktop.on_change(focus)
  stop_following = stop
end

-- Opens a workspace on $HOME on the focused display and moves to its Space once it has one.
function actions.create_workspace()
  if stop_following then
    stop_following()
  end

  follow_created(runtime.create_workspace())
end

-- Opens a tab in the current workspace, in the focused pane's directory.
function actions.create_tab()
  workbench.command("new_tab")
end

-- The focused display's workspace at a position, in the order of its Spaces.
function actions.select_workspace(index)
  local state = desktop.state()

  if state.pending_space then
    return
  end

  local space = displays.workspaces(state, displays.focused(state))[index]

  if space then
    desktop.activate_space(space.id)
  end
end

-- Takes the focused window, another application's, out of every layout into the backstage.
function actions.send_to_backstage()
  workbench.command("send_to_backstage")
end

-- Brings the focused display's layout back over a window that took it over.
function actions.end_takeover()
  workbench.command("end_takeover")
end

-- Binds the backstage switcher to a modified chord, as Cmd+Tab: each press opens it or moves
-- on, the chord with shift moves back, releasing the modifier lets the selected window take over
-- the display, and the modifier with escape closes it untouched. Returns a function that unbinds
-- it.
function actions.bind_backstage_switcher(chord)
  local modifiers, key = chord:match("^(.+)%+([^+]+)$")
  assert(modifiers, "The backstage switcher needs a modified chord")
  local stop_cancel

  local function close()
    if stop_cancel then
      stop_cancel()
      stop_cancel = nil
    end
  end

  local function cycle(step)
    return function()
      if workbench.command("cycle_backstage", { step = step }) and not stop_cancel then
        stop_cancel = shortcuts.bind_global(modifiers .. "+escape", function()
          close()
          workbench.command("close_backstage")
        end)
      end
    end
  end

  local function commit()
    if stop_cancel then
      close()
      workbench.command("take_over_selected")
    end
  end

  local stops = {
    shortcuts.bind_global(chord, cycle(1), { on_release = commit }),
    shortcuts.bind_global(modifiers .. "+shift+" .. key, cycle(-1), { on_release = commit }),
  }

  return function()
    close()
    for _, stop in ipairs(stops) do
      stop()
    end
  end
end

local function install()
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
  shortcuts.bind({ "c" }, actions.create_tab)
  shortcuts.bind({ "N" }, actions.create_workspace)
  shortcuts.bind({ "n" }, function()
    actions.step_tab(1, false)
  end)
  shortcuts.bind({ "p" }, function()
    actions.step_tab(-1, false)
  end)
  shortcuts.bind({ "," }, function()
    actions.step_tab(-1, true)
  end)
  shortcuts.bind({ "." }, function()
    actions.step_tab(1, true)
  end)

  for index = 1, 9 do
    local tab_index = index
    shortcuts.bind({ tostring(index) }, function()
      actions.select_tab(tab_index)
    end)
  end

  shortcuts.bind_global("ctrl+left", function()
    actions.step_space(-1)
  end)
  shortcuts.bind_global("ctrl+right", function()
    actions.step_space(1)
  end)

  actions.bind_backstage_switcher("alt+tab")
  shortcuts.bind_global("alt+b", actions.send_to_backstage)
  shortcuts.bind_global("alt+enter", actions.end_takeover)
end

return setmetatable({ actions = actions }, {
  __call = function()
    install()
  end,
})
