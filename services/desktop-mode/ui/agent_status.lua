-- How every surface presents an agent's status: its attention group, words, glyph and colors.
local ui = require("telar.ui")
local theme = require("telar.theme")

local AgentStatus = {}

local groups = {
  blocked = "needs_input",
  failed = "needs_input",
  working = "working",
  done = "done",
  ready = "idle",
  unknown = "unknown",
}

AgentStatus.group_titles = {
  needs_input = "NEEDS YOU",
  working = "WORKING",
  done = "DONE",
  idle = "IDLE",
  unknown = "UNKNOWN",
}

local labels = {
  working = "Working",
  failed = "Failed",
  done = "Done",
  ready = "Idle",
  unknown = "Unknown",
}

local reasons = {
  permission = "Needs permission",
  question = "Has a question",
  plan = "Plan to review",
  other = "Needs you",
}

-- Glyphs are drawn in a 12×12 box: a circle, plus a mark that tells statuses apart without color.
local circle = "M10.5 6 A4.5 4.5 0 1 1 1.5 6 A4.5 4.5 0 1 1 10.5 6"
local glyphs = {
  working = "M6 1.5 A4.5 4.5 0 1 1 1.5 6",
  blocked = circle .. " M6 3.6 L6 6.4 M6 8.2 L6 8.4",
  failed = circle .. " M4.4 4.4 L7.6 7.6 M7.6 4.4 L4.4 7.6",
  done = circle .. " M4 6.2 L5.4 7.6 L8.2 4.6",
  ready = circle,
  unknown = circle,
}

AgentStatus.glyph_size = 12

function AgentStatus.group(agent)
  return groups[agent.status] or "unknown"
end

function AgentStatus.colors(agent)
  return theme.status[agent.status] or theme.status.unknown
end

function AgentStatus.label(agent)
  if agent.status == "blocked" then
    return reasons[agent.blocked_reason] or reasons.other
  end

  return labels[agent.status] or labels.unknown
end

function AgentStatus.age(seconds)
  if seconds < 60 then
    return seconds < 5 and "now" or string.format("%ds", seconds)
  end

  if seconds < 3600 then
    return string.format("%dm", math.floor(seconds / 60))
  end

  if seconds < 86400 then
    return string.format("%dh", math.floor(seconds / 3600))
  end

  return string.format("%dd", math.floor(seconds / 86400))
end

function AgentStatus.title(agent)
  if agent.title ~= "" then
    return agent.title
  end

  return agent.name ~= "" and agent.name or agent.provider
end

function AgentStatus.new_glyph(parent)
  return ui.path({
    parent = parent,
    path = glyphs.unknown,
    width = AgentStatus.glyph_size,
    height = AgentStatus.glyph_size,
    fillMode = "NoResize",
    stroke_width = 1.5,
  })
end

function AgentStatus.paint_glyph(glyph, agent)
  glyph.path = glyphs[agent.status] or glyphs.unknown
  glyph.stroke = AgentStatus.colors(agent).color
end

return AgentStatus
