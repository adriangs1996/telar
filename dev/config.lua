local telar = require("telar")
local action = telar.action

local function select_tab(index)
	return action.select_tab({ index = index })
end

local function select_workspace(index)
	return action.select_workspace({ index = index })
end

local bar_colors = {
	blue = "#89b4fa",
	dim = "#6c7086",
	green = "#a6e3a1",
	peach = "#fab387",
	red = "#f38ba8",
}

local status_command = {
	"/bin/sh",
	"-c",
	[=[
set -u
umask 077

cache="${XDG_CACHE_HOME:-$HOME/.cache}/telar/bar"
a="$cache/a"
cx_file="$cache/codex.json"
cl_file="$cache/claude.json"
gw_file="$cache/gw"
out="$cache/status"
mkdir -p "$cache"

make() {
  cx="?"
  cx_max=-1
  cl="?"
  cl_max=-1
  gw=$(sed -n '1p' "$gw_file" 2>/dev/null || printf '%s' -1)
  bat=$(pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
  [ -n "$bat" ] || bat=-1

  if [ -s "$cx_file" ]; then
    cx=$(jq -r '(if type == "array" then ([.[] | select(.provider == "codex" and .usage != null)][0]) else . end) | .usage | [(.primary.usedPercent? | numbers | "5h:\(. | round)%"), (.secondary.usedPercent? | numbers | "7d:\(. | round)%")] | join(" ")' "$cx_file" 2>/dev/null || true)
    cx_max=$(jq -r '(if type == "array" then ([.[] | select(.provider == "codex" and .usage != null)][0]) else . end) | .usage | [.primary.usedPercent?, .secondary.usedPercent?] | map(select(type == "number")) | max // -1 | floor' "$cx_file" 2>/dev/null || printf '%s' -1)
    [ -n "$cx" ] || cx="?"
  fi

  if [ -s "$cl_file" ]; then
    cl=$(jq -r '([(.five_hour.utilization? | numbers | "5h:\(. | round)%"), (.seven_day.utilization? | numbers | "7d:\(. | round)%")] + [.limits[]? | select(.kind == "weekly_scoped" and .percent != null) | "\((.scope.model.display_name // "M")[0:1]):\(.percent | round)%"]) | unique | join(" ")' "$cl_file" 2>/dev/null || true)
    cl_max=$(jq -r '([.five_hour.utilization?, .seven_day.utilization?] + [.limits[]? | select(.kind == "weekly_scoped") | .percent?]) | map(select(type == "number")) | max // -1 | floor' "$cl_file" 2>/dev/null || printf '%s' -1)
    [ -n "$cl" ] || cl="?"
  fi

  next="$out.$$"
  printf 'gw=%s|bat=%s|cx=%s|cx_max=%s|cl=%s|cl_max=%s\n' "$gw" "$bat" "$cx" "$cx_max" "$cl" "$cl_max" >"$next"
  mv "$next" "$out"
}

now=$(date +%s)
last=$(sed -n '1p' "$a" 2>/dev/null || true)
case "$last" in ''|*[!0-9]*) last=0 ;; esac

if [ "$((now - last))" -ge 60 ]; then
  printf '%s\n' "$now" >"$a"
  cx_pid=""
  cl_pid=""
  cx_tmp=""
  cl_tmp=""

  cb=$(command -v codexbar 2>/dev/null || true)
  if [ -n "$cb" ]; then
    cx_tmp=$(mktemp "$cache/codex.XXXXXX")
    "$cb" usage --provider codex --format json --web-timeout 7 >"$cx_tmp" 2>/dev/null &
    cx_pid=$!
  fi

  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
  if [ -n "$token" ]; then
    version=$(claude --version 2>/dev/null | awk '{print $1}' || true)
    version=${version:-2.0.0}
    cl_tmp=$(mktemp "$cache/claude.XXXXXX")
    { printf 'header = "Authorization: Bearer %s"\n' "$token"; printf 'header = "anthropic-beta: oauth-2025-04-20"\nheader = "User-Agent: claude-code/%s"\n' "$version"; } | curl -fsS --max-time 7 "https://api.anthropic.com/api/oauth/usage" --config - -o "$cl_tmp" 2>/dev/null &
    cl_pid=$!
  fi

  ( sleep 8; [ -n "$cx_pid" ] && kill "$cx_pid" 2>/dev/null; [ -n "$cl_pid" ] && kill "$cl_pid" 2>/dev/null ) &
  wd=$!
  cx_rc=1
  cl_rc=1
  [ -z "$cx_pid" ] || { wait "$cx_pid"; cx_rc=$?; }
  [ -z "$cl_pid" ] || { wait "$cl_pid"; cl_rc=$?; }
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  if [ "$cx_rc" -eq 0 ] && jq -e 'if type == "array" then any(.[]; .provider == "codex" and .usage != null) else .usage != null end' "$cx_tmp" >/dev/null 2>&1; then
    mv "$cx_tmp" "$cx_file"
  fi
  if [ "$cl_rc" -eq 0 ] && jq -e '.five_hour.utilization != null or .seven_day.utilization != null or (.limits | type == "array")' "$cl_tmp" >/dev/null 2>&1; then
    mv "$cl_tmp" "$cl_file"
  fi
  [ -z "$cx_tmp" ] || rm -f "$cx_tmp"
  [ -z "$cl_tmp" ] || rm -f "$cl_tmp"

  gw=-1
  root="$HOME/sandbox/gwagent"
  if [ -f "$root/.gitmodules" ]; then
    gw=$(git config -f "$root/.gitmodules" --get-regexp '\.path$' 2>/dev/null | awk '{print $2}' | while IFS= read -r sub; do [ ! -e "$root/$sub/.git" ] || [ -z "$(git -C "$root/$sub" status --porcelain 2>/dev/null)" ] || printf 'x\n'; done | wc -l | tr -d ' ')
  fi
  printf '%s\n' "$gw" >"$gw_file"
  make
fi

[ -s "$out" ] || make
sed -n '1p' "$out"
	]=],
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
		return bar_colors.dim
	end

	if percent >= 80 then
		return bar_colors.red
	end

	if percent >= 50 then
		return bar_colors.peach
	end

	return bar_colors.green
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
			fg = bar_colors.blue,
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
			fg = battery <= 20 and bar_colors.red or bar_colors.green,
			bold = false,
		}
	end

	content[#content + 1] = {
		text = "| ",
	}

	if metrics.available then
		content[#content + 1] = {
			text = string.format(" %d%% ", metrics.cpu_percent),
			fg = bar_colors.peach,
		}

		content[#content + 1] = {
			text = "| ",
		}

		content[#content + 1] = {
			text = string.format(" %.1fG ", metrics.memory_used_decigib / 10),
			fg = "mauve",
		}
	end
	return content
end

return telar.config({
	api_version = 2,

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
				"gpt-5.6-sol",
				"--provider",
				"openai-codex",
				"--thinking",
				"medium",
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

		bars = {
			top = {
				right = telar.bar.command({
					command = status_command,
					every_ms = 60000,
					timeout_ms = 9500,
					render = render_quotas,
				}),
			},
			bottom = {
				left = telar.bar.command({
					command = status_command,
					every_ms = 1000,
					timeout_ms = 9500,
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

			-- Scrolling
			telar.bind_global({ "alt+-" }, action.scroll_pane({ direction = "up" })),
			telar.bind_global({ "alt+=" }, action.scroll_pane({ direction = "down" })),
		},
	},
})
