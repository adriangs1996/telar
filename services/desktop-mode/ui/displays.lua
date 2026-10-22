-- Each display is a desktop of its own: these find what belongs to one. Display IDs are the
-- strings the desktop state uses.
local displays = {}

-- The display a surface is on.
function displays.of(surface)
  local screen = surface.screen

  return screen and screen.id and string.format("%d", screen.id)
end

-- The display holding the focused Space.
function displays.focused(state)
  for _, space in ipairs(state.spaces) do
    if space.id == state.focused_space then
      return space.display
    end
  end
end

-- A display's Spaces, in Mission Control order.
function displays.spaces(state, display)
  local result = {}

  for _, space in ipairs(state.spaces) do
    if space.display == display then
      result[#result + 1] = space
    end
  end

  return result
end

-- A display's Spaces that hold a workspace, in Mission Control order: its workspaces' order.
function displays.workspaces(state, display)
  local result = {}

  for _, space in ipairs(state.spaces) do
    if space.display == display and space.workspace and not space.fullscreen then
      result[#result + 1] = space
    end
  end

  return result
end

-- The runtime view of the workspace a display shows, and the Space showing it.
function displays.view(runtime_state, desktop_state, display)
  local shown

  for _, space in ipairs(desktop_state.spaces) do
    if space.display == display and space.visible then
      shown = space
      break
    end
  end

  if not shown or not shown.workspace then
    return nil, shown
  end

  for _, view in ipairs(runtime_state.views) do
    if view.workspace.id == shown.workspace then
      return view, shown
    end
  end

  return nil, shown
end

return displays
