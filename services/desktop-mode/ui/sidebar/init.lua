-- The agents panel: every agent of the runtime, grouped in attention order, each a card that
-- jumps to its pane. It folds into a rail of status buttons, giving the workbench the width.
local ui = require("telar.ui")
local runtime = require("telar.runtime")
local desktop = require("telar.desktop")
local workbench = require("telar.workbench")
local theme = require("telar.theme")
local displays = require("displays")
local AgentStatus = require("agent_status")
local Icons = require("icons")
local Color = require("color")
local Card = require("sidebar.card")

local colors = theme.colors

local metrics = {
  rail_width = 52,
  -- Narrower than this, the sidebar is the rail, as after a reload while folded.
  rail_threshold = 100,
  expanded_width = 300,
  padding = 12,
  header_height = 52,
  button = 28,
  title_size = 14,
  chip_height = 26,
  chip_gap = 6,
  chip_padding = 10,
  list_gap = 10,
  group_height = 30,
  card_gap = 4,
  line_height = 16,
  glyph = 14,
  footer_height = 34,
  rail_item = 36,
  rail_gap = 6,
  empty_icon = 40,
  hover_ms = 120,
  move_ms = 200,
  fade_ms = 160,
  fold_ms = 240,
  press_scale = 0.98,
  press_ms = 90,
  enter_offset = 6,
  wheel_step = 120,
}

local filters = { all = "all", workspace = "workspace" }

local state = runtime.state()
local desktop_state = desktop.state()
local agents = runtime.agents()
local filter = filters.all
local folded = ui.surface.width < metrics.rail_threshold
local expanded_width = folded and metrics.expanded_width or ui.surface.width
local folding = false
-- Counts fold changes, so a quick second toggle outdates the first one's finishing step.
local fold_generation = 0
local cards, pool = {}, {}
local headers = {}
local rail_buttons = {}
local scroll = 0
local content_height = 0
local cancel_tick
local cancel_pulse
local pulse_frame = 0
local selected_pane
-- The agent a click asked for, until its workspace is on screen.
local pending_jump

local function rectangle(properties)
  local parent = properties.parent
  properties.parent = nil

  return ui.create("QtQuick", "Rectangle", properties, parent)
end

local function fade(item, opacity, duration)
  ui.animate(item, "opacity", { to = opacity, duration_ms = duration or metrics.fade_ms })
end

local panel = rectangle({
  color = colors.chrome,
  radius = theme.radius.large,
  clip = true,
  ["border.color"] = colors.border,
  ["border.width"] = 1,
})

local expanded = ui.item({ parent = panel, opacity = folded and 0 or 1, visible = not folded })
local rail = ui.item({ parent = panel, opacity = folded and 1 or 0, visible = folded })

local toggle = rectangle({
  parent = panel,
  x = metrics.padding,
  y = (metrics.header_height - metrics.button) / 2,
  width = metrics.button,
  height = metrics.button,
  radius = theme.radius.small,
  color = "transparent",
})

local toggle_icon = Icons.new("sidebar", { parent = toggle, color = colors.muted })
toggle_icon.x = (metrics.button - 16) / 2
toggle_icon.y = (metrics.button - 16) / 2

local title = ui.text({
  parent = expanded,
  text = "Agents",
  color = colors.text,
  x = metrics.padding + metrics.button + 10,
  ["font.pixelSize"] = metrics.title_size,
  ["font.weight"] = 600,
})

local count_pill = rectangle({
  parent = expanded,
  height = 18,
  radius = 9,
  color = colors.raised,
})

local count_label = ui.text({
  parent = count_pill,
  color = colors.muted,
  ["font.pixelSize"] = 11,
  ["font.weight"] = 600,
})

local divider = rectangle({ parent = panel, height = 1, color = colors.border })
local chips = {}
local viewport = ui.item({ parent = expanded, clip = true })
local content = ui.item({ parent = viewport })

local empty = ui.item({ parent = viewport, visible = false })
local empty_circle = rectangle({
  parent = empty,
  width = metrics.empty_icon,
  height = metrics.empty_icon,
  radius = metrics.empty_icon / 2,
  color = colors.raised,
})
local empty_icon = Icons.new("agents", { parent = empty_circle, color = colors.muted })
empty_icon.x = (metrics.empty_icon - 16) / 2
empty_icon.y = (metrics.empty_icon - 16) / 2
local empty_title = ui.text({
  parent = empty,
  color = colors.text,
  horizontalAlignment = "AlignHCenter",
  ["font.pixelSize"] = 13,
  ["font.weight"] = 600,
})
local empty_hint = ui.text({
  parent = empty,
  color = colors.muted,
  horizontalAlignment = "AlignHCenter",
  wrapMode = "WordWrap",
  ["font.pixelSize"] = 12,
})

local footer_divider = rectangle({ parent = expanded, height = 1, color = colors.border })
local status = ui.text({
  parent = expanded,
  textFormat = "PlainText",
  elide = "ElideRight",
  color = colors.muted,
  ["font.pixelSize"] = 11,
})

local function current_workspace()
  local view = displays.view(state, desktop_state, displays.of(ui.surface))

  return view and view.workspace.id
end

local function visible_agents()
  if filter == filters.all then
    return agents
  end

  local workspace = current_workspace()
  local result = {}

  for _, agent in ipairs(agents) do
    if agent.workspace == workspace then
      result[#result + 1] = agent
    end
  end

  return result
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

-- Pressing shrinks a control a little, so a click is felt before its effect arrives.
local function pressable(item, on_click)
  ui.on(item, "pointer_down", function(event)
    if event.button == "left" then
      ui.animate(item, "scale", { to = metrics.press_scale, duration_ms = metrics.press_ms })
    end
  end)

  for _, name in ipairs({ "pointer_up", "pointer_cancel" }) do
    ui.on(item, name, function()
      ui.animate(item, "scale", { to = 1, duration_ms = metrics.press_ms })
    end)
  end

  ui.on(item, "click", function(event)
    if event.button == "left" then
      on_click()
      event:stop_propagation()
    end
  end)
end

local function hoverable(item, paint)
  ui.on(item, "hover", function(event)
    paint(event.inside)
  end)
end

-- Cards ------------------------------------------------------------------------------------

local function make_card()
  local card = Card.new(content)

  hoverable(card.panel, function(inside)
    card:set_hovered(inside)
  end)

  pressable(card.panel, function()
    if card.agent then
      jump(card.agent)
    end
  end)

  return card
end

-- The checkouts and worktrees cards name, by ID.
local function card_context()
  local checkouts, worktrees = {}, {}

  for _, workspace in ipairs(state.workspaces or {}) do
    checkouts[workspace.id] = workspace
  end

  for _, worktree in ipairs(state.worktrees or {}) do
    worktrees[worktree.id] = worktree
  end

  return { checkouts = checkouts, worktrees = worktrees }
end

-- The pane focused in the active tab of the focused workspace, as the workbench reports it.
local function focused_pane()
  local snapshot = workbench.state()

  for _, workspace in ipairs(snapshot.workspaces or {}) do
    if workspace.id == snapshot.workspace then
      for _, tab in ipairs(workspace.tabs) do
        if tab.id == workspace.active_tab then
          return tab.focused and tab.focused:match("^pane:(%d+)$")
        end
      end
    end
  end
end

local function select_focused()
  selected_pane = focused_pane()

  for pane, card in pairs(cards) do
    card:set_selected(pane == selected_pane)
  end
end

-- A card or header enters fading in from a little below, and moves to its next place after.
local function place(item, entry, y)
  if not entry.placed then
    entry.placed = true
    item.opacity = 0
    item.y = y + metrics.enter_offset
    fade(item, 1)
  end

  if entry.target_y ~= y then
    entry.target_y = y
    ui.animate(item, "y", { to = y, duration_ms = metrics.move_ms })
  end
end

local function retire(item, entry, release)
  entry.placed = false
  entry.target_y = nil
  fade(item, 0)
  entry.cancel_retire = ui.after(metrics.fade_ms, function()
    entry.cancel_retire = nil
    item.visible = false
    release()
  end)
end

local function revive(item, entry)
  if entry.cancel_retire then
    entry.cancel_retire()
    entry.cancel_retire = nil
  end

  item.visible = true
end

local function header_for(group)
  local header = headers[group]

  if not header then
    header = { item = ui.item({ parent = content, height = metrics.group_height }) }
    header.label = ui.text({
      parent = header.item,
      x = 4,
      color = colors.label,
      text = AgentStatus.group_titles[group],
      ["font.pixelSize"] = 11,
      ["font.weight"] = 600,
      ["font.letterSpacing"] = 0.6,
    })
    header.count = ui.text({
      parent = header.item,
      horizontalAlignment = "AlignRight",
      ["font.pixelSize"] = 11,
      ["font.weight"] = 600,
    })
    headers[group] = header
  end

  return header
end

local function render_list(list, width)
  local context = card_context()
  local y = 0
  local counts, seen, seen_groups = {}, {}, {}

  for _, agent in ipairs(list) do
    local group = AgentStatus.group(agent)
    counts[group] = (counts[group] or 0) + 1
  end

  local group

  for _, agent in ipairs(list) do
    local next_group = AgentStatus.group(agent)

    if next_group ~= group then
      group = next_group
      seen_groups[group] = true
      local header = header_for(group)
      revive(header.item, header)
      header.item.width = width
      header.count.text = tostring(counts[group])
      header.count.color = group == "needs_input" and AgentStatus.colors(agent).color
        or colors.label
      header.count.x = width - 4 - header.count.implicitWidth
      header.label.y = metrics.group_height - header.label.implicitHeight - 6
      header.count.y = header.label.y
      place(header.item, header, y)
      y = y + metrics.group_height
    end

    local card = cards[agent.pane]

    if not card then
      card = table.remove(pool) or make_card()
      cards[agent.pane] = card
    end

    seen[agent.pane] = true
    revive(card.panel, card)
    card.selected = agent.pane == selected_pane
    local height = card:fill(agent, context, width)
    place(card.panel, card, y)
    y = y + height + metrics.card_gap
  end

  for pane, card in pairs(cards) do
    if not seen[pane] then
      cards[pane] = nil
      card:release()
      retire(card.panel, card, function()
        pool[#pool + 1] = card
      end)
    end
  end

  for name, header in pairs(headers) do
    if not seen_groups[name] and header.placed then
      retire(header.item, header, function() end)
    end
  end

  return y
end

-- The rail ------------------------------------------------------------------------------------

local function paint_rail_button(button)
  local agent = button.agent
  local palette = AgentStatus.colors(agent)
  local urgent = AgentStatus.group(agent) == "needs_input"
  local fill = urgent and palette.background or Color.fade(colors.chrome, 0)

  if button.hovered then
    fill = urgent and Color.blend(palette.color, palette.background, 0.12) or colors.hover
  end

  ui.animate(button.panel, "color", { to = fill, duration_ms = metrics.hover_ms })
  button.panel["border.color"] = urgent and palette.border or "transparent"
end

local function make_rail_button()
  local button = {}
  button.panel = rectangle({
    parent = rail,
    x = (metrics.rail_width - metrics.rail_item) / 2,
    width = metrics.rail_item,
    height = metrics.rail_item,
    radius = theme.radius.medium,
    color = "transparent",
    ["border.width"] = 1,
  })
  button.glyph = AgentStatus.new_glyph(button.panel, metrics.glyph)
  button.glyph.x = (metrics.rail_item - metrics.glyph) / 2
  button.glyph.y = (metrics.rail_item - metrics.glyph) / 2

  hoverable(button.panel, function(inside)
    button.hovered = inside

    if button.agent then
      paint_rail_button(button)
    end
  end)

  pressable(button.panel, function()
    if button.agent then
      jump(button.agent)
    end
  end)

  return button
end

local function render_rail(list)
  local top = metrics.header_height + metrics.padding
  local fits = math.floor((ui.surface.height - top) / (metrics.rail_item + metrics.rail_gap))
  local shown = math.min(#list, math.max(0, fits))

  for index = 1, shown do
    local button = rail_buttons[index] or make_rail_button()
    rail_buttons[index] = button
    button.agent = list[index]
    button.panel.y = top + (index - 1) * (metrics.rail_item + metrics.rail_gap)
    button.panel.visible = true
    AgentStatus.paint_glyph(button.glyph, button.agent)
    paint_rail_button(button)
  end

  for index = shown + 1, #rail_buttons do
    rail_buttons[index].panel.visible = false
    rail_buttons[index].agent = nil
  end
end

-- Layout ----------------------------------------------------------------------------------------

local function arrange()
  scroll = math.max(0, math.min(scroll, content_height - viewport.height))
  content.y = -scroll
end

local function paint_chip(chip)
  local selected = chip.filter == filter
  local fill = selected and colors.selected
    or (chip.hovered and colors.hover or Color.fade(colors.chrome, 0))
  ui.animate(chip.panel, "color", { to = fill, duration_ms = metrics.hover_ms })
  chip.label.color = selected and colors.text or colors.muted
end

local render

local function make_chip(name)
  local chip = { filter = name }
  chip.panel = rectangle({
    parent = expanded,
    height = metrics.chip_height,
    radius = metrics.chip_height / 2,
    color = "transparent",
  })
  chip.label = ui.text({
    parent = chip.panel,
    x = metrics.chip_padding,
    ["font.pixelSize"] = 12,
  })

  hoverable(chip.panel, function(inside)
    chip.hovered = inside
    paint_chip(chip)
  end)

  pressable(chip.panel, function()
    if filter ~= name then
      filter = name
      scroll = 0

      for _, other in ipairs(chips) do
        paint_chip(other)
      end

      render()
    end
  end)

  chips[#chips + 1] = chip
  return chip
end

make_chip(filters.all)
make_chip(filters.workspace)

local function update_chips()
  local workspace = current_workspace()
  local here = 0

  for _, agent in ipairs(agents) do
    if agent.workspace == workspace then
      here = here + 1
    end
  end

  local x = metrics.padding
  local texts = {
    string.format("All  %d", #agents),
    string.format("This workspace  %d", here),
  }

  for index, chip in ipairs(chips) do
    chip.panel.visible = #agents > 0
    chip.label.text = texts[index]
    chip.label.y = (metrics.chip_height - chip.label.implicitHeight) / 2
    chip.panel.width = chip.label.implicitWidth + 2 * metrics.chip_padding
    chip.panel.x = x
    chip.panel.y = metrics.header_height + metrics.padding
    x = x + chip.panel.width + metrics.chip_gap
    paint_chip(chip)
  end
end

local function render_empty(list)
  empty.visible = #list == 0

  if not empty.visible then
    return
  end

  local width = viewport.width
  empty_title.text = (#agents == 0 or filter == filters.all) and "No agents yet"
    or "No agents in this workspace"
  empty_hint.text = "Start Claude Code, Codex or Pi in any pane and it shows up here."
  empty.width = width
  empty_circle.x = (width - metrics.empty_icon) / 2
  empty_title.width = width
  empty_title.y = metrics.empty_icon + 14
  empty_hint.width = math.min(width, 220)
  empty_hint.x = (width - empty_hint.width) / 2
  empty_hint.y = empty_title.y + empty_title.implicitHeight + 6
  empty.y = math.max(0, (viewport.height - empty_hint.y - empty_hint.implicitHeight) / 2 - 40)
end

-- Ages advance on their own, so the next one to change brings a fresh snapshot.
local function schedule_tick(list)
  if cancel_tick then
    cancel_tick()
    cancel_tick = nil
  end

  local soonest

  for _, agent in ipairs(list) do
    local delay = AgentStatus.next_change_ms(agent)
    soonest = soonest and math.min(soonest, delay) or delay
  end

  if soonest then
    cancel_tick = ui.after(soonest, function()
      cancel_tick = nil
      agents = runtime.agents()
      render()
    end)
  end
end

local function pulse()
  pulse_frame = pulse_frame + 1
  local opacity = AgentStatus.pulse(pulse_frame)

  for _, card in pairs(cards) do
    card:pulse(opacity)
  end

  for _, button in ipairs(rail_buttons) do
    if button.agent then
      button.glyph.opacity = button.agent.status == "working" and opacity or 1
    end
  end
end

-- Working glyphs breathe, as in the GUI, on a slow timer that stops when nobody works.
local function schedule_pulse()
  local working = AgentStatus.most_urgent(agents, function(agent)
    return agent.status == "working"
  end)

  if working and not cancel_pulse then
    cancel_pulse = ui.after(AgentStatus.pulse_interval_ms, function()
      cancel_pulse = nil
      pulse()
      schedule_pulse()
    end)
  end
end

function render()
  local list = visible_agents()
  count_label.text = tostring(#agents)
  count_pill.width = count_label.implicitWidth + 12
  count_label.x = 6
  count_label.y = (count_pill.height - count_label.implicitHeight) / 2
  count_pill.x = title.x + title.implicitWidth + 8
  count_pill.y = (metrics.header_height - count_pill.height) / 2
  update_chips()
  content.width = viewport.width
  content_height = math.max(0, render_list(list, viewport.width) - metrics.card_gap)
  content.height = content_height
  render_empty(list)
  render_rail(agents)
  arrange()
  schedule_tick(list)
  schedule_pulse()
end

local function status_message()
  local managers = desktop_state.window_managers or {}
  local conflict = #managers > 0
    and (table.concat(managers, ", ") .. " also places windows. Quit it so Telar can.")
  local error = state.error or desktop_state.error or conflict

  return error or (not state.connected and "Connecting to runtime…") or nil, error ~= nil
end

local function layout()
  local width = expanded_width
  local height = ui.surface.height
  local inner = math.max(0, width - 2 * metrics.padding)
  local message, failed = status_message()
  local footer = message and metrics.footer_height or 0

  if not folding then
    panel.width = folded and metrics.rail_width or width
  end

  panel.height = height
  expanded.width, expanded.height = width, height
  rail.width, rail.height = metrics.rail_width, height
  title.y = (metrics.header_height - title.implicitHeight) / 2
  divider.y = metrics.header_height
  divider.width = math.max(width, metrics.rail_width)
  viewport.x = metrics.padding
  viewport.y = metrics.header_height + metrics.padding + metrics.chip_height + metrics.list_gap
  viewport.width = inner
  viewport.height = math.max(0, height - viewport.y - footer - metrics.padding / 2)
  footer_divider.visible = message ~= nil
  footer_divider.y = height - footer
  footer_divider.width = width
  status.visible = message ~= nil
  status.text = message or ""
  status.color = failed and colors.error or colors.muted
  status.x = metrics.padding
  status.width = inner
  status.y = height - footer + (footer - status.implicitHeight) / 2
  render()
end

-- Folding animates the panel inside the window, then gives the width to the workbench; unfolding
-- takes the width first and then animates into it.
local function set_folded(next)
  if next == folded then
    return
  end

  folded = next
  folding = true
  fold_generation = fold_generation + 1
  local generation = fold_generation
  local target = folded and metrics.rail_width or expanded_width

  if not folded then
    ui.surface.request_width(expanded_width)
  end

  expanded.visible, rail.visible = true, true
  ui.animate(panel, "width", {
    to = target,
    duration_ms = metrics.fold_ms,
    easing = "in_out_cubic",
  })
  fade(expanded, folded and 0 or 1, folded and metrics.fade_ms or metrics.fold_ms)
  fade(rail, folded and 1 or 0, folded and metrics.fold_ms or metrics.fade_ms)

  ui.after(metrics.fold_ms, function()
    if generation ~= fold_generation then
      return
    end

    folding = false
    expanded.visible, rail.visible = not folded, folded

    if folded then
      ui.surface.request_width(metrics.rail_width)
    end
  end)
end

hoverable(toggle, function(inside)
  ui.animate(toggle, "color", {
    to = inside and colors.hover or Color.fade(colors.chrome, 0),
    duration_ms = metrics.hover_ms,
  })
end)

pressable(toggle, function()
  set_folded(not folded)
end)

ui.on(viewport, "scroll", function(event)
  local delta = event.pixel_delta.y

  if delta == 0 then
    delta = event.angle_delta.y / metrics.wheel_step * metrics.line_height * 3
  end

  scroll = scroll - delta
  arrange()
  event:stop_propagation()
end)

workbench.on_change(select_focused)

runtime.on_agents(function(next_agents)
  agents = next_agents
  render()
end)

runtime.on_change(function(next_state)
  state = next_state
  layout()
  finish_jump()
end)

desktop.on_change(function(next_state, changes)
  desktop_state = next_state

  if changes.status or changes.focus or changes.spaces then
    layout()
  end
end)

ui.on(ui.surface, "resize", function()
  if not folded and not folding and ui.surface.width >= metrics.rail_threshold then
    expanded_width = ui.surface.width
  end

  layout()
end)

ui.on(ui.surface, "screen_changed", layout)
selected_pane = focused_pane()
layout()
