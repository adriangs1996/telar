-- The agents panel: every agent of the runtime, grouped in attention order, each a card that
-- jumps to its pane.
local ui = require("telar.ui")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local workbench = require("telar.workbench")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")

local colors = theme.colors

local metrics = {
  padding = 12,
  header_height = 44,
  title_size = 14,
  label_size = 12,
  detail_size = 11,
  group_height = 28,
  card_padding = 10,
  card_gap = 6,
  title_height = 18,
  line_height = 16,
  line_gap = 3,
  plan_height = 10,
  plan_bar = 4,
  plan_count_width = 32,
  age_width = 36,
  footer_height = 32,
  transition_ms = 140,
  wheel_step = 120,
}

local background = ui.create("QtQuick", "Rectangle", {
  color = colors.chrome,
  radius = theme.radius.large,
  ["border.color"] = colors.border,
  ["border.width"] = 1,
})

local title = ui.text({
  text = "Agents",
  color = colors.text,
  ["font.pixelSize"] = metrics.title_size,
  ["font.weight"] = 600,
})

local count_label = ui.text({
  color = colors.muted,
  ["font.pixelSize"] = metrics.detail_size,
  horizontalAlignment = "AlignRight",
})

local divider = ui.create("QtQuick", "Rectangle", { height = 1, color = colors.border })
local viewport = ui.item({ clip = true })
local content = ui.item({ parent = viewport })
local status = ui.text({
  textFormat = "PlainText",
  elide = "ElideRight",
  color = colors.muted,
  ["font.pixelSize"] = metrics.detail_size,
})

local state = runtime.state()
local desktop_state = desktop.state()
local agents = runtime.agents()
local cards, headers = {}, {}
local scroll = 0
local content_height = 0
-- The agent a click asked for, until its workspace is on screen.
local pending_jump

local function mono(properties)
  if theme.fonts.mono ~= "" then
    properties["font.family"] = theme.fonts.mono
  end

  return properties
end

local function space_of(workspace)
  for _, space in ipairs(desktop_state.spaces) do
    if space.workspace == workspace and not space.fullscreen then
      return space
    end
  end
end

-- Selecting a tab and focusing a pane only work while the workspace is on screen, so a jump to
-- another workspace activates its Space first and finishes once the runtime shows it.
local function finish_jump()
  local agent = pending_jump

  if not agent or not state.workspace or state.workspace.id ~= agent.workspace then
    return
  end

  pending_jump = nil

  local ok, error = pcall(runtime.select_tab, agent.tab)

  if ok then
    ok, error = pcall(workbench.command, "focus", { id = "pane:" .. agent.pane })
  end

  if not ok then
    print("Agent jump failed: " .. tostring(error))
  end
end

local function jump(agent)
  pending_jump = agent

  local space = space_of(agent.workspace)

  if space and not space.focused and not desktop_state.pending_space then
    desktop.activate_space(space.id)
    return
  end

  finish_jump()
end

local function paint(card)
  local agent = card.agent
  local palette = AgentStatus.colors(agent)
  local urgent = AgentStatus.group(agent) == "needs_input"
  local fill = urgent and palette.background or (card.hovered and colors.hover or colors.raised)

  if card.painted_fill ~= fill then
    card.painted_fill = fill
    ui.animate(card.panel, "color", { to = fill, duration_ms = metrics.transition_ms })
  end

  card.panel["border.color"] = urgent and palette.border or colors.border
end

local function make_card()
  local card = {}
  card.panel = ui.create("QtQuick", "Rectangle", {
    radius = theme.radius.medium,
    ["border.width"] = 1,
  }, content)
  card.glyph = AgentStatus.new_glyph(card.panel)
  card.title = ui.text({
    parent = card.panel,
    color = colors.text,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.label_size + 1,
    ["font.weight"] = 600,
  })
  card.age = ui.text({
    parent = card.panel,
    color = colors.muted,
    horizontalAlignment = "AlignRight",
    ["font.pixelSize"] = metrics.detail_size,
  })
  card.status = ui.text({
    parent = card.panel,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.detail_size,
  })
  card.event = ui.text(mono({
    parent = card.panel,
    color = colors.muted,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.detail_size,
  }))
  card.plan_track = ui.create("QtQuick", "Rectangle", {
    height = metrics.plan_bar,
    radius = metrics.plan_bar / 2,
    color = colors.border,
    clip = true,
  }, card.panel)
  card.plan_fill = ui.create("QtQuick", "Rectangle", {
    height = metrics.plan_bar,
  }, card.plan_track)
  card.plan_count = ui.text(mono({
    parent = card.panel,
    color = colors.muted,
    horizontalAlignment = "AlignRight",
    ["font.pixelSize"] = metrics.detail_size,
  }))
  card.location = ui.text({
    parent = card.panel,
    color = colors.muted,
    textFormat = "PlainText",
    elide = "ElideRight",
    ["font.pixelSize"] = metrics.detail_size,
  })

  ui.on(card.panel, "hover", function(event)
    card.hovered = event.inside
    paint(card)
  end)

  ui.on(card.panel, "click", function(event)
    if event.button == "left" and card.agent then
      jump(card.agent)
      event:stop_propagation()
    end
  end)

  return card
end

local function make_header()
  return ui.text({
    parent = content,
    color = colors.label,
    ["font.pixelSize"] = metrics.detail_size,
    ["font.weight"] = 600,
    ["font.letterSpacing"] = 0.6,
  })
end

-- Fills a card and returns its height, which depends on the lines the agent has.
local function fill_card(card, agent, width)
  local palette = AgentStatus.colors(agent)
  local inner = width - 2 * metrics.card_padding
  local y = metrics.card_padding

  card.agent = agent
  AgentStatus.paint_glyph(card.glyph, agent)
  card.glyph.x = metrics.card_padding
  card.glyph.y = y + (metrics.title_height - AgentStatus.glyph_size) / 2
  card.title.text = AgentStatus.title(agent)
  card.title.x = metrics.card_padding + AgentStatus.glyph_size + 8
  card.title.y = y
  card.title.width = math.max(0, inner - AgentStatus.glyph_size - 8 - metrics.age_width)
  card.age.text = AgentStatus.age(agent.status_age_s)
  card.age.x = width - metrics.card_padding - metrics.age_width
  card.age.y = y + 2
  card.age.width = metrics.age_width
  y = y + metrics.title_height + metrics.line_gap

  card.status.text = agent.name .. " · " .. AgentStatus.label(agent)
  card.status.color = palette.text
  card.status.x, card.status.y, card.status.width = metrics.card_padding, y, inner
  y = y + metrics.line_height + metrics.line_gap

  card.event.visible = agent.last_event ~= ""

  if card.event.visible then
    card.event.text = agent.last_event
    card.event.x, card.event.y, card.event.width = metrics.card_padding, y, inner
    y = y + metrics.line_height + metrics.line_gap
  end

  local plan = agent.plan
  card.plan_track.visible = plan ~= nil
  card.plan_count.visible = plan ~= nil

  if plan then
    local track = math.max(0, inner - metrics.plan_count_width - 8)
    card.plan_track.x = metrics.card_padding
    card.plan_track.y = y + (metrics.plan_height - metrics.plan_bar) / 2
    card.plan_track.width = track
    card.plan_fill.width = track * plan.done / plan.total
    card.plan_fill.color = palette.color
    card.plan_count.text = string.format("%d/%d", plan.done, plan.total)
    card.plan_count.x = width - metrics.card_padding - metrics.plan_count_width
    card.plan_count.y = y - 3
    card.plan_count.width = metrics.plan_count_width
    y = y + metrics.plan_height + metrics.line_gap + 2
  end

  card.location.text =
    string.format("%s › %s · pane %d", agent.workspace_label, agent.tab_label, agent.pane_index)
  card.location.x, card.location.y, card.location.width = metrics.card_padding, y, inner
  y = y + metrics.line_height + metrics.card_padding

  card.panel.width = width
  card.panel.height = y
  card.panel.visible = true
  paint(card)

  return y
end

local function arrange()
  scroll = math.max(0, math.min(scroll, content_height - viewport.height))
  content.y = -scroll
end

local function render()
  local width = viewport.width
  local y = 0
  local group
  local header_count = 0

  for index, agent in ipairs(agents) do
    local next_group = AgentStatus.group(agent)

    if next_group ~= group then
      group = next_group
      header_count = header_count + 1
      local header = headers[header_count] or make_header()
      headers[header_count] = header
      header.text = AgentStatus.group_titles[group]
      header.x = 2
      header.y = y + (header_count > 1 and metrics.card_gap or 0)
      header.visible = true
      y = header.y + metrics.group_height - metrics.card_gap
    end

    local card = cards[index] or make_card()
    cards[index] = card
    card.panel.y = y
    y = y + fill_card(card, agent, width) + metrics.card_gap
  end

  for index = #agents + 1, #cards do
    cards[index].panel.visible = false
    cards[index].agent = nil
    cards[index].hovered = false
  end

  for index = header_count + 1, #headers do
    headers[index].visible = false
  end

  content.width = width
  content_height = math.max(0, y - metrics.card_gap)
  content.height = content_height
  count_label.text = tostring(#agents)
  arrange()
end

local function update_status()
  local error = state.error or desktop_state.error
  status.color = error and colors.error or colors.muted
  status.text = error
    or (not state.connected and "Connecting to runtime…")
    or (#agents == 0 and "No agents running")
    or ""
end

local function layout()
  local width, height = ui.surface.width, ui.surface.height
  local inner = math.max(0, width - 2 * metrics.padding)
  background.width, background.height = width, height
  title.x = metrics.padding
  title.y = math.floor((metrics.header_height - title.implicitHeight) / 2)
  count_label.x = metrics.padding
  count_label.y = math.floor((metrics.header_height - count_label.implicitHeight) / 2)
  count_label.width = inner
  divider.x, divider.y, divider.width = 0, metrics.header_height, width
  viewport.x = metrics.padding
  viewport.y = metrics.header_height + metrics.padding
  viewport.width = inner
  viewport.height = math.max(0, height - viewport.y - metrics.footer_height)
  status.x = metrics.padding
  status.y = height
    - metrics.footer_height
    + math.floor((metrics.footer_height - status.implicitHeight) / 2)
  status.width = inner
  render()
end

ui.on(viewport, "scroll", function(event)
  local delta = event.pixel_delta.y

  if delta == 0 then
    delta = event.angle_delta.y / metrics.wheel_step * metrics.line_height * 3
  end

  scroll = scroll - delta
  arrange()
  event:stop_propagation()
end)

runtime.on_agents(function(next_agents)
  agents = next_agents
  render()
  update_status()
end)

runtime.on_change(function(next_state)
  state = next_state
  update_status()
  finish_jump()
end)

desktop.on_change(function(next_state, changes)
  desktop_state = next_state

  if changes.status then
    update_status()
  end
end)

ui.on(ui.surface, "resize", layout)
layout()
update_status()
