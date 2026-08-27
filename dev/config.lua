local telar = require("telar")
local action = telar.action

local function select_tab(index)
	return action.select_tab({ index = index })
end

local function select_workspace(index)
	return action.select_workspace({ index = index })
end

return telar.config({
	api_version = 2,

	runtime = {
		graphics = {
			pane_mib = 64,
			global_mib = 256,
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
				"gpt-5.6-luna",
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

		theme = telar.theme({
			base = "vesper",
			colors = {
				-- Let Ghostty provide the background so its opacity still applies.
				panel_bg = "default",
			},
		}),

		sidebar = {
			visible = true,
			renderer = "automatic",
		},

		keybindings = {
			-- Scrollback and copy mode.
			telar.bind({ "[" }, action.copy_mode()),

			-- Workspaces.
			telar.bind({ "N" }, action.new_workspace()),
			telar.bind({ "R" }, action.rename_workspace()),

			-- Pane focus.
			telar.bind_global({ "ctrl+h" }, action.focus_pane({ direction = "left" })),
			telar.bind_global({ "ctrl+j" }, action.focus_pane({ direction = "down" })),
			telar.bind_global({ "ctrl+k" }, action.focus_pane({ direction = "up" })),
			telar.bind_global({ "ctrl+l" }, action.focus_pane({ direction = "right" })),

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
		},
	},
})
