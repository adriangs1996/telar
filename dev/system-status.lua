local telar = require("telar")
local ui = telar.ui

local gpu_history = {}
local gpu_sample
local gpu_history_limit = 60

local function gpu_widget(gpu)
	gpu = type(gpu) == "table" and gpu or {}
	local percent = gpu.percent
	if type(percent) ~= "number" then
		gpu_history = {}
		gpu_sample = nil
		return ui.group({
			tooltip = { ui.heading("Local GPU"), ui.text(gpu.error or "Waiting for a GPU sample.") },
			ui.label({ text = "GPU N/A", tone = "muted" }),
		})
	end

	if gpu.sampled_at ~= gpu_sample then
		gpu_sample = gpu.sampled_at
		gpu_history[#gpu_history + 1] = percent
		if #gpu_history > gpu_history_limit then
			table.remove(gpu_history, 1)
		end
	end

	local tone = percent >= 98 and "danger" or percent >= 90 and "warning" or "neutral"
	local tooltip = {
		ui.heading("Local GPU · " .. (gpu.model or "GPU")),
		ui.kv({ key = "Utilization", value = string.format("%.0f%%", percent) }),
	}
	for _, metric in ipairs({ { "Renderer", gpu.renderer_percent }, { "Tiler", gpu.tiler_percent } }) do
		if type(metric[2]) == "number" then
			tooltip[#tooltip + 1] = ui.kv({ key = metric[1], value = string.format("%.0f%%", metric[2]) })
		end
	end
	if type(gpu.memory_used_bytes) == "number" then
		tooltip[#tooltip + 1] = ui.kv({
			key = "GPU memory in use",
			value = string.format("%.2f GiB", gpu.memory_used_bytes / 1024 ^ 3),
		})
	end
	return ui.group({
		tooltip = tooltip,
		priority = 70,
		ui.label({ text = "GPU", tone = tone }),
		ui.sparkline({ values = gpu_history, max = 100, tone = tone }),
		ui.label({ text = string.format("%.0f%%", percent), tone = tone }),
	})
end

return {
	bar = telar.bar.command({
		command = { "/bin/sh", "-c", 'exec python3 "${TELAR_DEVELOPMENT_CONFIG%/*}/bar.py" --gpu' },
		every_ms = 1000,
		timeout_ms = 2000,
		render = function(ctx)
			local ok, state = pcall(telar.json.decode, ctx.output or "")
			state = ok and type(state) == "table" and state or {}
			return {
				ui.group({
					tooltip = { ui.clock("%A, %e %B %Y") },
					ui.clock("%H:%M"),
					ui.clock({ format = "%d/%m", tone = "muted", priority = 30 }),
				}),
				ui.metrics({ "battery", "cpu", "memory" }),
				gpu_widget(state.gpu),
				ui.group({ ui.label("Cybervenom") }),
			}
		end,
	}),
}
