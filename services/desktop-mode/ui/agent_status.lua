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

-- Whether the agent is doing something the person may want to see from afar.
function AgentStatus.active(agent)
  local group = AgentStatus.group(agent)

  return group == "needs_input" or group == "working"
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

-- Minutes at the finest, so an age changes at most once a minute.
function AgentStatus.age(seconds)
  if seconds < 60 then
    return "now"
  end

  if seconds < 3600 then
    return string.format("%dm", math.floor(seconds / 60))
  end

  if seconds < 86400 then
    return string.format("%dh", math.floor(seconds / 3600))
  end

  return string.format("%dd", math.floor(seconds / 86400))
end

-- What the agent is about, when its title says more than its name. Agents put a spinner or
-- symbol before their terminal title ("✳ Claude Code"), which says nothing here.
function AgentStatus.title(agent)
  local title = agent.title:gsub("^[\128-\255]+%s+", "")

  if title == "" or title:lower() == agent.name:lower() then
    return nil
  end

  return title
end

-- The agent's title, or its name when the title adds nothing.
function AgentStatus.headline(agent)
  return AgentStatus.title(agent) or (agent.name ~= "" and agent.name or agent.provider)
end

function AgentStatus.location(agent)
  local place = agent.workspace_label

  if agent.tab_label ~= "" then
    place = place .. " › " .. agent.tab_label
  end

  return string.format("%s · pane %d", place, agent.pane_index)
end

-- The first agent `accepts`, which is the most urgent one since agents come in attention order.
function AgentStatus.most_urgent(agents, accepts)
  for _, agent in ipairs(agents) do
    if accepts(agent) then
      return agent
    end
  end
end

-- How long a working agent has been at it: seconds during its first minute, then as `age`.
function AgentStatus.duration(seconds)
  if seconds < 60 then
    return string.format("%ds", seconds)
  end

  return AgentStatus.age(seconds)
end

-- What the status corner of a card says: the duration while working, the age while idle and
-- the status word otherwise.
function AgentStatus.corner(agent)
  if agent.status == "working" then
    return "Working " .. AgentStatus.duration(agent.status_age_s)
  end

  if agent.status == "ready" then
    return AgentStatus.age(agent.status_age_s)
  end

  return AgentStatus.label(agent)
end

-- How long until what `corner` writes for the agent changes, in milliseconds.
function AgentStatus.next_change_ms(agent)
  local seconds = agent.status_age_s

  if agent.status == "working" and seconds < 60 then
    return 1000
  end

  local step = seconds < 3600 and 60 or seconds < 86400 and 3600 or 86400

  return (step - seconds % step) * 1000
end

-- The working glyph's opacity at a pulse frame: six steps between 1 and 0.65 over 17 frames,
-- as the GUI pulses it.
AgentStatus.pulse_interval_ms = 120

function AgentStatus.pulse(frame)
  local step = math.floor((frame % 17) * 6 / 17)

  return 0.65 + 0.35 * math.abs(step - 3) / 3
end

function AgentStatus.new_glyph(parent, size)
  size = size or AgentStatus.glyph_size

  return ui.path({
    parent = parent,
    path = glyphs.unknown,
    width = size,
    height = size,
    fillMode = "NoResize",
    scale = size / AgentStatus.glyph_size,
    transformOrigin = "TopLeft",
    stroke_width = 1.5,
  })
end

function AgentStatus.paint_glyph(glyph, agent)
  glyph.path = glyphs[agent.status] or glyphs.unknown
  glyph.stroke = AgentStatus.colors(agent).color
end

return AgentStatus
