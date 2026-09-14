local telar = require("telar")
local action = telar.action

local function select_tab(index)
	return action.select_tab({ index = index })
end

local function select_workspace(index)
	return action.select_workspace({ index = index })
end

-- Semantic roles follow the active theme, including after a live reload.
local bar_colors = {
	accent = "accent",
	secondary = "subtext0",
	muted = "overlay1",
	success = "green",
	warning = "yellow",
	danger = "red",
	info = "teal",
}

local status_command = {
	"/bin/sh",
	"-c",
	'exec python3 "${XDG_CONFIG_HOME:-$HOME/.config}/telar/bar/status.py"',
}

local function status_fields(output)
	local fields = {}

	for key, value in string.gmatch(output, "([%w_]+)=([^|]*)") do
		fields[key] = value
	end

	return fields
end

local function quota_color(value)
	local percent = tonumber(value)

	if not percent or percent < 0 then
		return bar_colors.muted
	end

	if percent >= 80 then
		return bar_colors.danger
	end

	if percent >= 50 then
		return bar_colors.warning
	end

	return bar_colors.success
end

local function battery_icon(percent)
	if percent <= 10 then
		return "󰁺"
	end

	if percent <= 35 then
		return "󰁼"
	end

	if percent <= 60 then
		return "󰁿"
	end

	if percent <= 85 then
		return "󰂁"
	end

	return "󰂄"
end

local function render_quotas(ctx)
	local fields = status_fields(ctx.output)

	return {
		{
			text = string.format("󱚞 CX %s ", fields.cx or "?"),
			fg = quota_color(fields.cx_max),
			bold = false,
		},
		{
			text = string.format(" CL %s ", fields.cl or "?"),
			fg = quota_color(fields.cl_max),
			bold = false,
		},
	}
end

local function render_status(ctx)
	local fields = status_fields(ctx.output)
	local metrics = ctx.metrics
	local content = {
		{
			text = string.format(
				"󰃰 %02d/%02d %02d:%02d ",
				ctx.time.day,
				ctx.time.month,
				ctx.time.hour,
				ctx.time.minute
			),
			fg = bar_colors.secondary,
			bold = false,
		},
	}

	content[#content + 1] = {
		text = "| ",
	}

	local battery = tonumber(fields.bat)

	if not battery or battery < 0 then
		battery = metrics.battery_percent
	end

	if battery then
		content[#content + 1] = {
			text = string.format("%s %d%% ", battery_icon(battery), battery),
			fg = battery <= 20 and bar_colors.danger or bar_colors.success,
			bold = false,
		}
	end

	content[#content + 1] = {
		text = "| ",
	}

	if metrics.available then
		content[#content + 1] = {
			text = string.format(" %d%% ", metrics.cpu_percent),
			fg = bar_colors.accent,
		}

		content[#content + 1] = {
			text = "| ",
		}

		content[#content + 1] = {
			text = string.format(" %.1fG ", metrics.memory_used_decigib / 10),
			fg = bar_colors.info,
		}
	end
	return content
end

return telar.config({
	api_version = 2,

	theme = require("osaka-jade"),

	gui = {
		window = {
			background_opacity = 0.95,
			background_blur = 20,
			titlebar = false,
			padding = { x = 2, y = 0 },
		},
		font = {
			family = "DejaVu Sans Mono",
			size = 18,
			line_height = 1.4, -- Ghostty: adjust-cell-height = 40%.
			letter_spacing = 0,
			thicken = true,
			thicken_strength = 255,
		},
		cursor = {
			style = "block",
			blink = true,
		},
	},

	runtime = {
		engine = {
			command = {
				"pi",
				"--mode",
				"rpc",
				"--no-session",
				"--no-tools",
				"--no-extensions",
				"--no-skills",
				"--no-context-files",
				"--model",
				"gpt-6-astra",
				"--provider",
				"openai-codex",
				"--thinking",
				"low",
			},
			timeout_ms = 20000,
			idle_timeout_ms = 300000,
		},

		proxy = {
			enabled = true,
			ca_dir = "state/proxy",
		},

		agent_descriptions = {
			command = {
				"codex",
				"exec",
				"--ephemeral",
				"--ignore-rules",
				"--skip-git-repo-check",
				"--model",
				"gpt-6-astra",
				"-c",
				'model_reasoning_effort="low"',
				"-",
			},
			timeout_ms = 15000,
		},
	},

	client = {
		icons = "nerd-font",
		prefix = "ctrl+s",
		pane_gaps = false,

		sidebar = {
			visible = true,
			renderer = "automatic",
		},

		bars = {
			top = {
				right = telar.bar.command({
					command = status_command,
					every_ms = 60000,
					timeout_ms = 2000,
					render = render_quotas,
				}),
			},
			bottom = {
				left = telar.bar.command({
					command = status_command,
					every_ms = 1000,
					timeout_ms = 2000,
					render = render_status,
				}),
				right = telar.bar.tabs(),
			},
		},

		keybindings = {
			-- Scrollback and copy mode.
			telar.bind({ "[" }, action.copy_mode()),

			-- Workspaces.
			telar.bind({ "N" }, action.new_workspace()),
			telar.bind({ "R" }, action.rename_workspace()),

			-- Pane focus.

			-- telar.bind_global({ "ctrl+h" }, action.focus_pane({ direction = "left" })),
			-- telar.bind_global({ "ctrl+j" }, action.focus_pane({ direction = "down" })),
			-- telar.bind_global({ "ctrl+k" }, action.focus_pane({ direction = "up" })),
			-- telar.bind_global({ "ctrl+l" }, action.focus_pane({ direction = "right" })),

			telar.bind_global({ "ctrl+h" }, telar.action.navigate_pane({ direction = "left" })),
			telar.bind_global({ "ctrl+j" }, telar.action.navigate_pane({ direction = "down" })),
			telar.bind_global({ "ctrl+k" }, telar.action.navigate_pane({ direction = "up" })),
			telar.bind_global({ "ctrl+l" }, telar.action.navigate_pane({ direction = "right" })),

			-- Side-by-side and stacked splits.
			telar.bind({ "s" }, action.split_pane({ direction = "horizontal" })),
			telar.bind({ "t" }, action.split_pane({ direction = "vertical" })),

			-- Tabs.
			telar.bind({ "n" }, action.new_tab()),
			telar.bind({ "r" }, action.rename_tab()),
			telar.bind({ "X" }, action.close_tab()),

			telar.bind({ "1" }, select_tab(1)),
			telar.bind({ "2" }, select_tab(2)),
			telar.bind({ "3" }, select_tab(3)),
			telar.bind({ "4" }, select_tab(4)),
			telar.bind({ "5" }, select_tab(5)),
			telar.bind({ "6" }, select_tab(6)),
			telar.bind({ "7" }, select_tab(7)),
			telar.bind({ "8" }, select_tab(8)),
			telar.bind({ "9" }, select_tab(9)),

			telar.bind_global({ "alt+1" }, select_workspace(1)),
			telar.bind_global({ "alt+2" }, select_workspace(2)),
			telar.bind_global({ "alt+3" }, select_workspace(3)),
			telar.bind_global({ "alt+4" }, select_workspace(4)),
			telar.bind_global({ "alt+5" }, select_workspace(5)),
			telar.bind_global({ "alt+6" }, select_workspace(6)),
			telar.bind_global({ "alt+7" }, select_workspace(7)),
			telar.bind_global({ "alt+8" }, select_workspace(8)),
			telar.bind_global({ "alt+9" }, select_workspace(9)),

			-- Fullscreen and resize.
			telar.bind({ "f" }, action.toggle_pane_fullscreen()),
			telar.bind_global({ "alt+h" }, action.resize_pane({ direction = "left" })),
			telar.bind_global({ "alt+j" }, action.resize_pane({ direction = "down" })),
			telar.bind_global({ "alt+k" }, action.resize_pane({ direction = "up" })),
			telar.bind_global({ "alt+l" }, action.resize_pane({ direction = "right" })),

			-- Related Telar controls.
			telar.bind({ "x" }, action.close_pane()),
			telar.bind({ "b" }, action.toggle_sidebar()),
			telar.bind({ "w" }, action.toggle_workspace_list()),
			telar.bind({ "d" }, action.detach()),

			-- Sidebar
			telar.bind_global({ "alt+n" }, action.resize_sidebar({ direction = "left" })),
			telar.bind_global({ "alt+m" }, action.resize_sidebar({ direction = "right" })),

			telar.bind_global({ "ctrl+r" }, "history-palette"),
			telar.bind_global({ "ctrl+e" }, action.suggest_command()),

			-- Scrolling
			telar.bind_global({ "alt+-" }, action.scroll_pane({ direction = "up" })),
			telar.bind_global({ "alt+=" }, action.scroll_pane({ direction = "down" })),
		},
	},
})
