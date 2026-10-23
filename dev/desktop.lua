local shortcuts = require("telar.shortcuts")
local desktop = require("telar.desktop")
local workbench = require("telar.workbench")
local actions = require("shortcuts").actions

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

-- Mirrors the effective keymap of dev/config.lua: its client.keybindings plus the GUI
-- defaults they leave in place. GUI actions without a desktop equivalent stay unbound.
shortcuts.set_prefix("ctrl+s")

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

local function command(action, options)
	return function()
		workbench.command(action, options)
	end
end

local arrows = { "left", "right", "up", "down" }
local vim = { h = "left", j = "down", k = "up", l = "right" }

-- Splits: s/t from dev/config.lua, % and " from the GUI defaults.
shortcuts.bind({ "s" }, command("split", { axis = "horizontal" }))
shortcuts.bind({ "t" }, command("split", { axis = "vertical" }))

shortcuts.bind({ "x" }, command("close"))
shortcuts.bind({ "f" }, command("maximize"))

for _, direction in ipairs(arrows) do
	shortcuts.bind({ direction }, command("navigate", { direction = direction }))
	shortcuts.bind_global("alt+" .. direction, command("resize", { direction = direction }))
end

for key, direction in pairs(vim) do
	shortcuts.bind_global("ctrl+" .. key, command("navigate", { direction = direction }))
end

-- Tabs and workspaces: n and N from dev/config.lua.
shortcuts.bind({ "n" }, actions.create_tab)
shortcuts.bind({ "N" }, actions.create_workspace)
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
	shortcuts.bind({ tostring(index) }, function()
		actions.select_tab(index)
	end)
	shortcuts.bind_global("alt+" .. index, function()
		actions.select_workspace(index)
	end)
end

-- Desktop-only actions, on keys the GUI leaves free.
shortcuts.bind({ "o" }, command("cycle"))
shortcuts.bind({ "F" }, command("float"))
shortcuts.bind_global("ctrl+left", function()
	actions.step_space(-1)
end)
shortcuts.bind_global("ctrl+right", function()
	actions.step_space(1)
end)

-- The backstage: alt+tab picks a window out of it, Cmd+Tab style; alt+b sends the focused window
-- there and alt+enter brings the layout back.
actions.bind_backstage_switcher("alt+tab")
shortcuts.bind_global("alt+b", actions.send_to_backstage)
shortcuts.bind_global("alt+enter", actions.end_takeover)

desktop.theme({ preset = "dark" })

desktop.configure_surface("wallpaper", {
	module = "wallpaper",
	options = { fit = "cover" },
})

desktop.configure_surface("topbar", {
	module = "topbar",
})

desktop.configure_surface("sidebar", {
	module = "sidebar",
})

desktop.configure_surface("workbench", {
	module = "workbench",
	options = {
		windows = {
			["com.spotify.client"] = "backstage",
		},
	},
})
