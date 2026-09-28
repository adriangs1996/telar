local telar = require("telar")
local action = telar.action

local function select_tab(index)
	return action.select_tab({ index = index })
end

local function select_workspace(index)
	return action.select_workspace({ index = index })
end

local ui = telar.ui
local usage = require("usage")

-- status.py returns the cached status line at once and refreshes the caches
-- in the background; the Claude and Codex caches are passed through as JSON.
local bar_command = {
	"/bin/sh",
	"-c",
	[[
cache="${XDG_CACHE_HOME:-$HOME/.cache}/telar/bar"
status=$(python3 "${XDG_CONFIG_HOME:-$HOME/.config}/telar/bar/status.py")
printf '{"status":"%s","claude":' "$status"
if [ -s "$cache/claude.json" ]; then cat "$cache/claude.json"; else printf null; fi
printf ',"codex":'
if [ -s "$cache/codex.json" ]; then cat "$cache/codex.json"; else printf null; fi
printf '}'
]],
}

local hour = 3600
local week = 7 * 24 * hour

local function status_fields(line)
	local fields = {}
	for key, value in string.gmatch(line or "", "([%w_]+)=([^|]*)") do
		fields[key] = value
	end
	return fields
end

-- Claude's usage endpoint reports one limit per window.
local function claude_provider(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local provider = { name = "Claude", url = "https://claude.ai/settings/usage", windows = {} }
	for _, limit in ipairs(raw.limits or {}) do
		local window
		if limit.kind == "session" then
			window = { id = "5h", title = "Current session", seconds = 5 * hour }
		elseif limit.kind == "weekly_all" then
			window = { id = "7d", title = "This week", seconds = week }
		elseif limit.kind == "weekly_scoped" and limit.scope and limit.scope.model then
			local model = limit.scope.model.display_name or "Model"
			window = { id = model:sub(1, 1), title = model .. " this week", seconds = week }
		end
		if window and limit.percent then
			window.used = limit.percent
			window.resets_at = limit.resets_at
			provider.windows[#provider.windows + 1] = window
		end
	end
	return provider
end

-- codexbar reports a primary and a secondary window and reset credits.
local function codex_provider(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local entry
	for _, item in ipairs(raw) do
		if item.provider == "codex" and item.usage then
			entry = item.usage
			break
		end
	end
	if not entry then
		return nil
	end
	local provider = { name = "Codex", url = "https://chatgpt.com/codex/settings/usage", windows = {}, credits = {} }
	for _, window in ipairs({ entry.primary or false, entry.secondary or false }) do
		if window and window.usedPercent then
			local minutes = window.windowMinutes or 0
			local weekly = minutes >= 24 * 60
			provider.windows[#provider.windows + 1] = {
				id = weekly and "7d" or "5h",
				title = weekly and "This week" or "Current session",
				used = window.usedPercent,
				resets_at = window.resetsAt,
				seconds = minutes * 60,
			}
		end
	end
	local credits = entry.codexResetCredits and entry.codexResetCredits.credits or {}
	for _, credit in ipairs(credits) do
		if credit.status == "available" then
			provider.credits[#provider.credits + 1] = {
				title = "1 free " .. (credit.title or "reset"):lower(),
				expires_at = credit.expires_at,
			}
		end
	end
	return provider
end

local function bar_data(ctx)
	if not ctx.output or ctx.output == "" then
		return {}
	end
	local raw = telar.json.decode(ctx.output)
	return {
		status = status_fields(raw.status),
		claude = claude_provider(raw.claude),
		codex = codex_provider(raw.codex),
	}
end

local function render_right(ctx)
	local data = bar_data(ctx)
	local components = {}
	local dirty = tonumber(data.status and data.status.gw)
	if dirty and dirty > 0 then
		components[#components + 1] = ui.group({
			tooltip = string.format("%d gwagent submodules with changes", dirty),
			priority = 30,
			ui.badge({ text = "gw " .. dirty, tone = "warning" }),
		})
	end
	if data.codex then
		components[#components + 1] = usage.group(data.codex, { mark = "codex", panel = "codex", priority = 60 })
	end
	if data.claude then
		components[#components + 1] = usage.group(data.claude, { mark = "claude", panel = "claude", priority = 90 })
	end
	return components
end

local function quota_panel(name, title)
	return telar.panel({
		title = title,
		mark = name,
		width = 460,
		command = bar_command,
		timeout_ms = 3000,
		every_ms = 30000,
		render = function(ctx)
			local provider = bar_data(ctx)[name]
			if not provider then
				return ui.text("No usage reported yet.")
			end
			return usage.panel(provider, ctx)
		end,
	})
end

return telar.config({
	api_version = 2,

	-- theme = require("osaka-jade"),
	theme = "pierre-dark-soft",

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
		window_title = "{pane_title}",
		editor = "nvim",
		icons = "nerd-font",
		prefix = "ctrl+s",
		pane_gaps = false,

		sidebar = {
			visible = true,
		},

		panels = {
			claude = quota_panel("claude", "Claude usage"),
			codex = quota_panel("codex", "Codex usage"),
		},

		bars = {
			bottom = {
				left = telar.bar.static({
					ui.group({
						tooltip = { ui.clock("%A, %e %B %Y") },
						ui.clock("%H:%M"),
						ui.clock({ format = "%d/%m", tone = "muted", priority = 30 }),
					}),
					ui.metrics({ "battery", "cpu", "memory" }),
				}),
				center = telar.bar.tabs(),
				right = telar.bar.command({
					command = bar_command,
					every_ms = 60000,
					timeout_ms = 3000,
					render = render_right,
				}),
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

			telar.bind_global({ "ctrl+p" }, telar.action.path_picker()),

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
			telar.bind({ "u" }, action.open_panel("claude")),
			telar.bind_global({ "ctrl+e" }, action.suggest_command()),

			-- Scrolling
			telar.bind_global({ "alt+-" }, action.scroll_pane({ direction = "up" })),
			telar.bind_global({ "alt+=" }, action.scroll_pane({ direction = "down" })),
		},
	},
})
