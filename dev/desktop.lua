local shortcuts = require("telar.shortcuts")
local desktop = require("telar.desktop")

local function move_workspace(offset)
	local state = desktop.state()

	if state.pending_space then
		return
	end

	local current

	for _, space in ipairs(state.spaces) do
		if space.id == state.focused_space then
			current = space
			break
		end
	end

	if not current then
		return
	end

	local spaces = {}
	local index

	for _, space in ipairs(state.spaces) do
		if space.display == current.display and space.workspace and not space.fullscreen then
			spaces[#spaces + 1] = space
			if space.id == current.id then
				index = #spaces
			end
		end
	end

	if index and #spaces > 1 then
		local target = (index - 1 + offset) % #spaces + 1
		desktop.activate_space(spaces[target].id)
	end
end

local function select_workspace(index)
	local state = desktop.state()

	if state.pending_space then
		return
	end

	local display

	for _, space in ipairs(state.spaces) do
		if space.id == state.focused_space then
			display = space.display
			break
		end
	end

	if not display then
		return
	end

	local position = 0

	for _, space in ipairs(state.spaces) do
		if space.display == display and space.workspace and not space.fullscreen then
			position = position + 1

			if position == index then
				desktop.activate_space(space.id)
				return
			end
		end
	end
end

shortcuts.set_prefix("ctrl+b")

shortcuts.bind_global("cmd+h", function()
	move_workspace(-1)
end)

shortcuts.bind_global("cmd+l", function()
	move_workspace(1)
end)

for index = 1, 9 do
	local target = index

	shortcuts.bind_global("cmd+" .. target, function()
		select_workspace(target)
	end)
end

require("topbar")
