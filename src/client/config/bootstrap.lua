local telar = {}
telar.action = {}
telar.bar = {}
telar.input = {}

function telar.config(value)
	return value
end

function telar.theme(value)
	return value
end

function telar.plugin(value)
	return value
end

function telar.bar.tabs()
	return { bar_kind = "tabs" }
end

function telar.bar.metrics()
	return { bar_kind = "metrics" }
end

function telar.bar.machines()
	return { bar_kind = "machines" }
end

function telar.bar.static(value)
	return { bar_kind = "static", value = value }
end

function telar.bar.dynamic(options)
	return {
		bar_kind = "dynamic",
		every_ms = options.every_ms,
		render = options.render,
	}
end

function telar.bar.command(options)
	return {
		bar_kind = "command",
		command = options.command,
		every_ms = options.every_ms,
		timeout_ms = options.timeout_ms,
		render = options.render,
	}
end

-- Components. Each constructor returns a plain table tagged with `ui`; Telar
-- validates the fields when the bar or panel is rendered.
telar.ui = {}

local function component(kind, options, key)
	if type(options) ~= "table" then
		options = key and { [key] = options } or {}
	end
	local value = { ui = kind }
	for name, field in pairs(options) do
		value[name] = field
	end
	return value
end

for kind, key in pairs({
	label = "text",
	icon = "name",
	mark = "name",
	meter = false,
	sparkline = false,
	badge = "text",
	clock = "format",
	metric = "name",
	group = false,
	heading = "text",
	text = "text",
	meter_row = false,
	kv = false,
	callout = false,
	actions = false,
	button = false,
	divider = false,
}) do
	local component_kind = kind
	local shorthand = key or nil
	telar.ui[kind] = function(options)
		return component(component_kind, options, shorthand)
	end
end

-- A group of built-in host metrics, each formatted by Telar.
function telar.ui.metrics(names)
	local group = { ui = "group" }
	for index, name in ipairs(names or { "cpu", "memory", "battery" }) do
		group[index] = telar.ui.metric(name)
	end
	return group
end

-- A panel opened above the bottom bar. `render` builds its components from
-- `ctx`; with `command`, `ctx.output` holds the command's output. Without
-- `every_ms` it renders once per opening and on refresh_panel.
function telar.panel(options)
	local source
	if options.command then
		source = telar.bar.command({
			command = options.command,
			every_ms = options.every_ms,
			timeout_ms = options.timeout_ms,
			render = options.render,
		})
	else
		source = telar.bar.dynamic({ every_ms = options.every_ms, render = options.render })
	end
	return {
		panel_kind = "panel",
		title = options.title,
		mark = options.mark,
		icon = options.icon,
		width = options.width,
		refresh = options.every_ms ~= nil,
		source = source,
	}
end

function telar.action.open_panel(options)
	if type(options) == "string" then
		options = { panel = options }
	end
	return { kind = "open-panel", panel = options.panel }
end

function telar.bind(keys, action)
	return { keys = keys, action = action, expression = false, prefixed = true }
end

function telar.bind_expr(keys, callback)
	return { keys = keys, action = callback, expression = true, prefixed = true }
end

function telar.bind_global(keys, action)
	return { keys = keys, action = action, expression = false, prefixed = false }
end

function telar.bind_expr_global(keys, callback)
	return { keys = keys, action = callback, expression = true, prefixed = false }
end

function telar.input.consume()
	return { input_kind = "consume" }
end

function telar.input.forward()
	return { input_kind = "forward" }
end

function telar.input.key(value)
	return { input_kind = "keys", keys = { value } }
end

function telar.input.keys(values)
	return { input_kind = "keys", keys = values }
end

function telar.input.paste(value)
	return { input_kind = "paste", text = value }
end

function telar.action.scroll_pane(options)
	return { kind = "scroll-pane", direction = options.direction }
end

function telar.action.split_pane(options)
	return { kind = "split-pane", direction = options.direction }
end

function telar.action.focus_pane(options)
	return { kind = "focus-pane", direction = options.direction }
end

function telar.action.navigate_pane(options)
	return { kind = "navigate-pane", direction = options.direction }
end

function telar.action.resize_pane(options)
	return { kind = "resize-pane", direction = options.direction }
end

function telar.action.resize_sidebar(options)
	return { kind = "resize-sidebar", direction = options.direction }
end

function telar.action.select_tab(options)
	return { kind = "select-tab", index = options.index }
end

function telar.action.select_workspace(options)
	return { kind = "select-workspace", index = options.index }
end

function telar.action.select_tab_offset(options)
	return { kind = "select-tab-offset", offset = options.offset }
end

function telar.action.move_tab(options)
	return { kind = "move-tab", direction = options.direction }
end

function telar.action.plugin(options)
	return { kind = "plugin", plugin = options.plugin, action = options.action }
end

function telar.action.command_tab(options)
	return { kind = "command-tab", command = options.command, label = options.label }
end

function telar.action.notification(options)
	return {
		kind = "notification",
		title = options.title,
		body = options.body,
		level = options.level,
		duration_ms = options.duration_ms,
		pane_id = options.pane_id,
		tab_id = options.tab_id,
		workspace_id = options.workspace_id,
	}
end

for _, name in ipairs({
	"toggle-pane-fullscreen",
	"toggle-sidebar",
	"toggle-workspace-list",
	"leave-worktree",
	"new-workspace",
	"rename-workspace",
	"close-pane",
	"new-tab",
	"rename-tab",
	"close-tab",
	"detach",
	"copy-mode",
	"history-palette",
	"path-picker",
	"suggest-command",
	"close-panel",
	"refresh-panel",
	"next-machine",
	"previous-machine",
	"machine-picker",
	"add-machine",
}) do
	local stable_name = name
	telar.action[name:gsub("-", "_")] = function()
		return { kind = stable_name }
	end
end

_G.telar = telar

_G.require = function(name)
	if name == "telar" then
		return telar
	end
	error("module '" .. tostring(name) .. "' is not available", 2)
end
