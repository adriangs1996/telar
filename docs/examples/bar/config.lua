-- A native bottom bar: a clock, host metrics and agent quotas, each opening a
-- panel with the details. Copy this directory next to your config.lua, or
-- require it from there, and point `usage_command` at your own data.

local telar = require("telar")
local ui = telar.ui
local usage = require("usage")

-- Any command that prints the document `usage.lua` describes. Telar runs
-- it without a shell, off the interface thread, and passes its output to
-- the render callbacks below as `ctx.output`.
local usage_command = {
	"/bin/sh",
	"-c",
	'cat "${TELAR_USAGE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/telar/usage.json}"',
}

local function providers(ctx)
	if not ctx.output or ctx.output == "" then
		return {}
	end
	return telar.json.decode(ctx.output).providers or {}
end

local function quota_panel(name)
	return telar.panel({
		title = name == "claude" and "Claude usage" or "Codex usage",
		mark = name,
		width = 460,
		command = usage_command,
		every_ms = 30000,
		render = function(ctx)
			local provider = providers(ctx)[name]
			if not provider then
				return ui.text("No usage reported yet.")
			end
			return usage.panel(provider, ctx)
		end,
	})
end

return telar.config({
	api_version = 2,
	client = {
		panels = {
			claude = quota_panel("claude"),
			codex = quota_panel("codex"),
		},

		keybindings = {
			telar.bind({ "u" }, telar.action.open_panel("claude")),
		},

		bars = {
			bottom = {
				-- Built-in components need no callback: the clock follows the
				-- minute and the metrics follow the runtime's samples.
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
					command = usage_command,
					every_ms = 60000,
					render = function(ctx)
						local list = providers(ctx)
						local groups = {}
						if list.codex then
							groups[#groups + 1] = usage.group(list.codex, { mark = "codex", panel = "codex", priority = 60 })
						end
						if list.claude then
							groups[#groups + 1] = usage.group(list.claude, { mark = "claude", panel = "claude", priority = 90 })
						end
						return groups
					end,
				}),
			},
		},
	},
})
