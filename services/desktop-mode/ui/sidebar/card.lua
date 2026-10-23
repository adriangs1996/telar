-- One agent of the sidebar, in three rows as the GUI draws it: where it works and its status,
-- the session title, then what happens now. The card paints only; the sidebar owns its position
-- and order.
local ui = require("telar.ui")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")
local Icons = require("icons")
local Color = require("color")

local colors = theme.colors

local Card = {}
Card.__index = Card

Card.metrics = {
  padding_x = 12,
  padding_y = 10,
  row_gap = 3,
  place_height = 18,
  title_height = 20,
  detail_line = 17,
  provider = 14,
  glyph = 13,
  corner_gap = 6,
  accent = 3,
  plan_cells = 8,
  plan_cell = 8,
  plan_cell_gap = 2,
  plan_cell_height = 4,
  hover_ms = 120,
  flash_ms = 900,
  flash_opacity = 0.35,
}

local metrics = Card.metrics
local transparent = Color.fade(colors.chrome, 0)

local function rectangle(properties)
  local parent = properties.parent
  properties.parent = nil

  return ui.create("QtQuick", "Rectangle", properties, parent)
end

local function text(properties)
  properties.textFormat = "PlainText"
  properties.elide = properties.elide or "ElideRight"

  return ui.text(properties)
end

function Card.new(parent)
  local self = setmetatable({}, Card)
  self.panel = rectangle({
    parent = parent,
    radius = theme.radius.medium,
    color = transparent,
    ["border.width"] = 1,
    ["border.color"] = "transparent",
  })
  self.flash_layer = rectangle({
    parent = self.panel,
    radius = theme.radius.medium,
    opacity = 0,
  })
  self.accent = rectangle({
    parent = self.panel,
    x = 0,
    width = metrics.accent,
    radius = metrics.accent / 2,
  })
  self.provider = Icons.new_provider({ parent = self.panel, size = metrics.provider })
  self.place = text({
    parent = self.panel,
    color = colors.muted,
    ["font.pixelSize"] = 12,
  })
  self.glyph = AgentStatus.new_glyph(self.panel, metrics.glyph)
  self.corner = text({
    parent = self.panel,
    elide = "ElideNone",
    ["font.pixelSize"] = 12,
  })
  self.title = text({
    parent = self.panel,
    color = colors.text,
    ["font.pixelSize"] = 14,
    ["font.weight"] = 500,
  })
  self.detail = text({
    parent = self.panel,
    wrapMode = "WordWrap",
    maximumLineCount = 2,
    ["font.pixelSize"] = 12,
  })
  self.plan_count = text({
    parent = self.panel,
    color = colors.muted,
    elide = "ElideNone",
    ["font.pixelSize"] = 11,
  })

  if theme.fonts.mono ~= "" then
    self.plan_count["font.family"] = theme.fonts.mono
  end

  self.cells = {}

  for index = 1, metrics.plan_cells do
    self.cells[index] = rectangle({
      parent = self.panel,
      width = metrics.plan_cell,
      height = metrics.plan_cell_height,
      radius = metrics.plan_cell_height / 2,
    })
  end

  return self
end

-- `⎇ branch  +12 −3 · 2  ↑1  ✓ test`: where a task lives, how much it changed and how its last
-- command ended.
local function task_facts(worktree)
  local facts = "⎇ " .. worktree.branch

  if worktree.diff_files > 0 then
    facts = facts
      .. string.format(
        "  +%d −%d · %d",
        worktree.diff_added,
        worktree.diff_removed,
        worktree.diff_files
      )
  end

  if worktree.commits_ahead > 0 then
    facts = facts .. string.format("  ↑%d", worktree.commits_ahead)
  end

  local command = worktree.command

  if command and command.state == "exited" then
    facts = facts .. "  " .. (command.exit == 0 and "✓ " or "✕ ") .. command.label
  end

  return facts
end

-- Where the agent works: its task's facts, or its workspace and branch.
local function place_text(agent, context)
  local worktree = agent.work_tree and context.worktrees[agent.work_tree]

  if worktree then
    return task_facts(worktree)
  end

  local checkout = context.checkouts[agent.workspace]
  local branch = checkout and checkout.branch or ""
  local place = agent.workspace_label

  if branch ~= "" then
    place = place .. " · ⎇ " .. branch .. (checkout.dirty and "*" or "")
  end

  return place
end

-- What happens now: the question it waits on, its plan step, its final answer, or its last
-- event, in the color that says which.
local function detail(agent, palette)
  local status = agent.status

  if status == "blocked" or status == "failed" then
    return agent.last_event, palette.text
  end

  if status == "done" or status == "ready" then
    local final = agent.final_message ~= "" and agent.final_message or agent.last_event

    return final, colors.muted
  end

  if agent.plan and agent.plan.step ~= "" then
    return agent.plan.step, colors.muted
  end

  return agent.last_event, colors.label
end

-- Draws the plan's cells at `x`, one per task up to eight, and returns where its text starts.
function Card:fill_plan(plan, palette, x, y)
  local cells = plan and math.min(plan.total, metrics.plan_cells) or 0
  local filled = cells > 0 and math.ceil(plan.done * cells / plan.total) or 0
  local cell_y = y + (metrics.detail_line - metrics.plan_cell_height) / 2

  for index, cell in ipairs(self.cells) do
    cell.visible = index <= cells

    if cell.visible then
      cell.x = x
      cell.y = cell_y
      cell.color = index <= filled and palette.color or colors.border
      x = x + metrics.plan_cell + metrics.plan_cell_gap
    end
  end

  self.plan_count.visible = cells > 0

  if cells == 0 then
    return x
  end

  self.plan_count.text = string.format("%d/%d", plan.done, plan.total)
  self.plan_count.x = x + 2
  self.plan_count.y = y + (metrics.detail_line - self.plan_count.implicitHeight) / 2

  return self.plan_count.x + self.plan_count.implicitWidth + 8
end

-- Fills the card for `agent` and returns its height. `context` carries the workspace checkouts
-- and worktrees, by ID.
function Card:fill(agent, context, width)
  local previous = self.agent
  self.agent = agent
  self.panel.width = width
  self.flash_layer.width = width
  AgentStatus.paint_glyph(self.glyph, agent)

  if agent.status ~= "working" then
    self.glyph.opacity = 1
  end

  if previous and previous.pane == agent.pane and previous.status ~= agent.status then
    self:flash(agent)
  end

  local height = self:fill_full(agent, context, width)

  self.panel.height = height
  self.flash_layer.height = height
  self.accent.height = math.max(0, height - 2 * metrics.padding_y)
  self.accent.y = metrics.padding_y
  self:paint()

  return height
end

function Card:fill_full(agent, context, width)
  local palette = AgentStatus.colors(agent)
  local x = metrics.padding_x
  local right = width - metrics.padding_x
  local y = metrics.padding_y

  self.corner.text = AgentStatus.corner(agent)
  self.corner.color = palette.text
  self.corner.x = right - self.corner.implicitWidth
  self.corner.y = y + (metrics.place_height - self.corner.implicitHeight) / 2
  self.glyph.x = self.corner.x - metrics.corner_gap - metrics.glyph
  self.glyph.y = y + (metrics.place_height - metrics.glyph) / 2

  Icons.paint_provider(self.provider, agent.provider, colors.muted)
  self.provider.x = x
  self.provider.y = y + (metrics.place_height - metrics.provider) / 2
  local place_x = self.provider.visible and (x + metrics.provider + 6) or x
  self.place.visible = true
  self.place.text = place_text(agent, context)
  self.place.x = place_x
  self.place.y = y + (metrics.place_height - self.place.implicitHeight) / 2
  self.place.width = math.max(0, self.glyph.x - 10 - place_x)
  y = y + metrics.place_height + metrics.row_gap

  self.title.text = AgentStatus.headline(agent)
  self.title.x, self.title.y, self.title.width = x, y, right - x
  y = y + metrics.title_height + metrics.row_gap

  local words, color = detail(agent, palette)
  local detail_x = agent.status == "working" and self:fill_plan(agent.plan, palette, x, y) or x

  if agent.status ~= "working" then
    self:fill_plan(nil, palette, x, y)
  end

  self.detail.visible = words ~= ""
  self.detail.text = words
  self.detail.color = color
  self.detail.maximumLineCount = agent.status == "working" and 1 or 2
  self.detail.x, self.detail.y = detail_x, y
  self.detail.width = math.max(0, right - detail_x)
  local lines = self.detail.visible and math.max(metrics.detail_line, self.detail.implicitHeight)
    or (self.plan_count.visible and metrics.detail_line or 0)

  return y + lines + metrics.padding_y
end

-- Selected follows the focused pane; an agent that needs the person keeps a bar of its color.
function Card:paint()
  local agent = self.agent
  local palette = AgentStatus.colors(agent)
  local urgent = AgentStatus.group(agent) == "needs_input"
  local fill = transparent

  if self.selected then
    fill = colors.raised
  elseif self.hovered then
    fill = colors.hover
  elseif urgent then
    fill = Color.fade(palette.background, 0.7)
  end

  if self.painted_fill ~= fill then
    self.painted_fill = fill
    ui.animate(self.panel, "color", { to = fill, duration_ms = metrics.hover_ms })
  end

  self.panel["border.color"] = self.selected and colors.border_strong or "transparent"
  self.accent.visible = urgent
  self.accent.color = palette.color
end

function Card:set_selected(selected)
  if self.selected ~= selected then
    self.selected = selected
    self:paint()
  end
end

function Card:set_hovered(hovered)
  self.hovered = hovered

  if self.agent then
    self:paint()
  end
end

-- A status change lights the card in its new color for a moment.
function Card:flash(agent)
  self.flash_layer.color = AgentStatus.colors(agent).color
  self.flash_layer.opacity = metrics.flash_opacity
  ui.animate(self.flash_layer, "opacity", {
    to = 0,
    duration_ms = metrics.flash_ms,
    easing = "out_cubic",
  })
end

function Card:pulse(opacity)
  self.glyph.opacity = self.agent and self.agent.status == "working" and opacity or 1
end

function Card:release()
  self.agent = nil
  self.hovered = false
  self.selected = false
  self.painted_fill = nil
end

return Card
