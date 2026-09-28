-- Turns a usage document into bar components and panel blocks. A copy of
-- docs/examples/bar/usage.lua: configuration modules live beside the
-- configuration that requires them.
--
-- The document is whatever your own command prints; this module only reads
-- this shape, so the source of the numbers stays yours:
--
-- {
--   "providers": {
--     "claude": {
--       "name": "Claude",
--       "url": "https://claude.ai/settings/usage",
--       "windows": [
--         { "id": "5h", "title": "Current session", "used": 22,
--           "resets_at": "2026-09-26T11:20:00Z", "seconds": 18000 }
--       ],
--       "credits": [ { "title": "1 free full reset", "expires_at": "2026-10-22T20:34:38Z" } ]
--     }
--   }
-- }
--
-- `used` is a percentage. `resets_at` (UTC) and `seconds`, the window's
-- length, are optional; with both, a marker shows where usage would be if it
-- were spread evenly over the window.

local telar = require("telar")
local ui = telar.ui

local usage = {}

local weekdays = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 for a proleptic Gregorian date.
local function days(year, month, day)
	if month <= 2 then
		year = year - 1
	end
	local era = (year >= 0 and year or year - 399) // 400
	local year_of_era = year - era * 400
	local day_of_year = (153 * (month + (month > 2 and -3 or 9)) + 2) // 5 + day - 1
	local day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
	return era * 146097 + day_of_era - 719468
end

-- Seconds since the epoch for an ISO 8601 UTC timestamp.
function usage.epoch(text)
	if type(text) ~= "string" then
		return nil
	end
	local year, month, day, hour, minute, second = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not year then
		return nil
	end
	return days(tonumber(year), tonumber(month), tonumber(day)) * 86400
		+ tonumber(hour) * 3600
		+ tonumber(minute) * 60
		+ tonumber(second)
end

-- The local wall clock for a Unix time, from the offset between the local
-- time and the Unix time the callback context carries.
local function wall(ctx, unix)
	local now = ctx.time
	local local_now = days(now.year, now.month, now.day) * 86400 + now.hour * 3600 + now.minute * 60 + now.second
	local shifted = unix + (local_now - now.unix_seconds)
	local day = shifted // 86400
	local seconds = shifted % 86400
	return {
		day = day,
		weekday = (day + 4) % 7 + 1,
		hour = seconds // 3600,
		minute = seconds % 3600 // 60,
		today = days(now.year, now.month, now.day),
	}
end

local function civil(day)
	local shifted = day + 719468
	local era = (shifted >= 0 and shifted or shifted - 146096) // 146097
	local day_of_era = shifted - era * 146097
	local year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
	local day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	local month_index = (5 * day_of_year + 2) // 153
	local month = month_index + (month_index < 10 and 3 or -9)
	return month, day_of_year - (153 * month_index + 2) // 5 + 1
end

-- "today at 13:20", "Sunday at 19:00" or "2 Oct at 19:20".
function usage.when(ctx, unix)
	local at = wall(ctx, unix)
	local clock = string.format("%02d:%02d", at.hour, at.minute)
	if at.day == at.today then
		return "today at " .. clock
	end
	if at.day - at.today < 7 then
		return weekdays[at.weekday] .. " at " .. clock
	end
	local month, day = civil(at.day)
	return string.format("%d %s at %s", day, months[month], clock)
end

-- How much of the window has elapsed, 0..1, or nil without reset data.
function usage.expected(window, ctx)
	local resets = usage.epoch(window.resets_at)
	if not resets or not window.seconds or window.seconds <= 0 then
		return nil
	end
	local elapsed = 1 - (resets - ctx.time.unix_seconds) / window.seconds
	-- Outside the window, a marker would only say where the window is not.
	if elapsed <= 0 or elapsed > 1 then
		return nil
	end
	return elapsed
end

function usage.tone(used)
	if used >= 80 then
		return "danger"
	end
	if used >= 50 then
		return "warning"
	end
	return "neutral"
end

-- The provider's windows as meters in its bar group.
function usage.group(provider, options)
	options = options or {}
	local group = {
		mark = options.mark,
		priority = options.priority or 80,
		on_click = options.panel and telar.action.open_panel(options.panel) or nil,
		tooltip = {},
		ui.label({ text = provider.name, tone = "muted", priority = 10 }),
	}
	for index, window in ipairs(provider.windows or {}) do
		group[#group + 1] = ui.meter({
			label = window.id,
			value = window.used / 100,
			tone = usage.tone(window.used),
			-- The first window stays longest when the bar narrows.
			priority = index == 1 and group.priority or group.priority - 20,
		})
		group.tooltip[#group.tooltip + 1] = ui.meter_row({
			label = window.title or window.id,
			value = window.used / 100,
			tone = usage.tone(window.used),
		})
	end
	return ui.group(group)
end

-- One sentence on the pace of the tightest window.
function usage.headline(provider, ctx)
	local tightest
	for _, window in ipairs(provider.windows or {}) do
		local expected = usage.expected(window, ctx)
		if expected and expected > 0 then
			local pace = window.used / 100 / expected
			if not tightest or pace > tightest.pace then
				tightest = { pace = pace, window = window }
			end
		end
	end
	if not tightest then
		return "Usage this period."
	end
	local resets = usage.when(ctx, usage.epoch(tightest.window.resets_at))
	if tightest.pace <= 0.9 then
		return "On track. You reach the reset " .. resets .. " with room to spare."
	end
	if tightest.pace <= 1.1 then
		return "On pace to use it all by the reset " .. resets .. "."
	end
	return "Ahead of pace. " .. (tightest.window.title or tightest.window.id) .. " may run out before " .. resets .. "."
end

-- The provider's panel: the pace, a row per window, credits and links.
function usage.panel(provider, ctx)
	local blocks = { ui.heading(usage.headline(provider, ctx)), ui.divider() }
	for _, window in ipairs(provider.windows or {}) do
		local resets = usage.epoch(window.resets_at)
		blocks[#blocks + 1] = ui.meter_row({
			label = window.title or window.id,
			detail = resets and ("Resets " .. usage.when(ctx, resets)) or nil,
			value = window.used / 100,
			marker = usage.expected(window, ctx),
			tone = usage.tone(window.used),
		})
	end
	for _, credit in ipairs(provider.credits or {}) do
		local expires = usage.epoch(credit.expires_at)
		blocks[#blocks + 1] = ui.callout({
			icon = "agent-done",
			text = credit.title,
			detail = expires and ("Expires " .. usage.when(ctx, expires)) or nil,
			button = provider.url and ui.button({ text = "Open", url = provider.url }) or nil,
		})
	end
	local buttons = { ui.button({ text = "Refresh", action = telar.action.refresh_panel() }) }
	if provider.url then
		table.insert(buttons, 1, ui.button({ text = "Open in browser", url = provider.url }))
	end
	blocks[#blocks + 1] = ui.actions(buttons)
	return blocks
end

return usage
