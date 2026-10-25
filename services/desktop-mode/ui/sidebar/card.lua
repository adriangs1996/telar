-- The normal agent card. Layout, typography, colors and interaction remain editable in Lua.
local ui = require("telar.ui")
local theme = require("telar.theme")
local AgentStatus = require("agent_status")

local Card = {}
Card.__index = Card

Card.metrics = {
  reference_font = 15,
  chrome_scale = 1,
  title_ratio = 0.87,
  small_ratio = 0.73,
  line_ratio = 1.3,
  icon_ratio = 0.85,
  minimum_text = 6,
  padding_x = 10,
  padding_y = 8,
  title_gap = 4,
  detail_gap = 2,
  gap = 6,
  spacing = 3,
  project_gap = 4,
  project_minimum = 24,
  radius = 8,
  mark_side = 14,
  artwork_side = 20,
  minimum_artwork = 8,
  maximum_artwork = 96,
  provider_opacity = 0.6,
  image_poll_ms = 16,
  image_poll_limit = 125,
}

Card.font_family = theme.fonts.ui ~= "" and theme.fonts.ui or "IBM Plex Sans"
Card.unknown_provider_glyph = "\238\172\178"
Card.palette = {
  surface0 = theme.colors.raised,
  surface1 = theme.colors.border,
  text = theme.colors.text,
  subtext0 = theme.colors.muted,
  overlay1 = theme.colors.label,
  working = theme.status.working.color,
  done = theme.status.done.color,
  blocked = theme.status.blocked.color,
  failed = theme.status.failed.color,
}

local words = { working = "Working", done = "Done", failed = "Failed", unknown = "Unknown" }
local reasons = { permission = "Approval", question = "Question", plan = "Review plan" }
local glyphs = { working = "◌", done = "✓", failed = "✕", unknown = "?" }
local blocked_glyphs = { permission = "⚠", question = "?", plan = "≡" }
local providers = { claude = true, codex = true, pi = true, cursor = true, opencode = true }
local image_status = { null = 0, ready = 1, loading = 2 }

local function round(value)
  return math.floor(value + 0.5)
end

local function encode(value)
  return value:gsub("([^%w._~-])", function(byte)
    return string.format("%%%02X", string.byte(byte))
  end)
end

local function text(parent)
  return ui.text({
    parent = parent,
    textFormat = "PlainText",
    elide = "ElideRight",
    wrapMode = "NoWrap",
    renderType = "NativeRendering",
    horizontalAlignment = "AlignLeft",
    transformOrigin = "TopLeft",
    ["font.family"] = Card.font_family,
    ["font.weight"] = 400,
    ["font.hintingPreference"] = "PreferNoHinting",
  })
end

local function image(parent)
  return ui.image({ parent = parent, fillMode = "PreserveAspectFit", smooth = true })
end

local function source(target, value)
  if target.source ~= value then
    target.source = value
  end
end

local function geometry()
  local metrics = Card.metrics
  local scale = ui.surface.scale or 1
  local ratio = scale * theme.terminal.font.size / metrics.reference_font
  local function px(logical)
    return round(logical * ratio) / scale
  end
  local small = math.max(
    metrics.minimum_text,
    round(theme.terminal.font.size * scale * metrics.chrome_scale * metrics.small_ratio)
  )
  local title = math.max(
    metrics.minimum_text,
    round(theme.terminal.font.size * scale * metrics.chrome_scale * metrics.title_ratio)
  )

  return {
    scale = scale,
    ratio = ratio,
    px = px,
    small = small,
    title = title,
    small_row = math.ceil(small * metrics.line_ratio) / scale,
    title_row = math.ceil(title * metrics.line_ratio) / scale,
    small_icon = round(small * metrics.icon_ratio) / scale,
    title_icon = round(title * metrics.icon_ratio) / scale,
  }
end

function Card.new(parent)
  local self = setmetatable({}, Card)
  self.panel = ui.create("QtQuick", "Rectangle", {
    color = "transparent",
    clip = true,
    ["border.color"] = "transparent",
  }, parent)
  self.project_icon = image(self.panel)
  self.folder = image(self.panel)
  self.folder.smooth = false
  self.project = text(self.panel)
  self.state_icon = image(self.panel)
  self.state_icon.smooth = false
  self.state = text(self.panel)
  self.state.elide = "ElideNone"
  self.title = text(self.panel)
  self.detail = text(self.panel)
  self.provider = image(self.panel)
  self.custom_provider = text(self.panel)
  self.custom_provider.elide = "ElideNone"
  self.provider.opacity = Card.metrics.provider_opacity
  self.custom_provider.opacity = Card.metrics.provider_opacity

  return self
end

function Card:set_text(label, value, bounds, pixels)
  local scale = self.geometry.scale
  label["font.pixelSize"] = pixels
  label.scale = 1 / scale
  label.text = value
  label.x = bounds.x
  label.width = math.max(0, bounds.width * scale)
  label.height = label.implicitHeight
  label.y = bounds.y + math.floor((bounds.height * scale - label.implicitHeight) / 2) / scale
end

function Card:glyph(target, label, bounds)
  local url = string.format(
    "image://artwork/glyph/%s/%s/%d/%s",
    encode(label.text),
    encode(Card.font_family),
    label.pixels * 2,
    label.color:sub(-6)
  )
  source(target, url)
  target.x, target.y = bounds.x, bounds.y
  target.width, target.height = math.max(0, bounds.width), math.max(0, bounds.height)
end

-- A favicon load changes the project slot's width. Poll only this asynchronous cold load;
-- the provider returns a transparent 1px image when the workspace has no favicon.
function Card:load_favicon(path)
  local g, metrics = self.geometry, Card.metrics
  local side = math.max(
    metrics.minimum_artwork,
    math.min(metrics.maximum_artwork, round(metrics.mark_side * g.ratio))
  )
  local url = path ~= "" and string.format("image://artwork/favicon/%s/%d", encode(path), side)
    or ""

  if self.favicon_url == url then
    return
  end

  self.favicon_url = url
  self.has_favicon = false
  if self.cancel_icon then
    self.cancel_icon()
    self.cancel_icon = nil
  end
  source(self.project_icon, url)

  if url == "" then
    return
  end

  local attempts = 0
  local function check()
    self.cancel_icon = nil
    local status = self.project_icon.status
    if
      (
        status == image_status.loading
        or status == image_status.null
        or status == "Loading"
        or status == "Null"
      ) and attempts < metrics.image_poll_limit
    then
      attempts = attempts + 1
      self.cancel_icon = ui.after(metrics.image_poll_ms, check)
      return
    end

    self.has_favicon = (status == image_status.ready or status == "Ready")
      and self.project_icon.implicitWidth > 1
    if self.agent then
      self:layout()
    end
  end

  self.cancel_icon = ui.after(0, check)
end

function Card:fill(agent, context, width)
  self.agent, self.context = agent, context
  self.geometry = geometry()
  self.panel.width = width
  self:load_favicon(agent.workspace_kind ~= "worktree" and context.paths[agent.workspace] or "")
  self:layout()

  return self.panel.height
end

function Card:spacing()
  return self.geometry.px(Card.metrics.spacing)
end

function Card:layout()
  local agent, context = self.agent, self.context
  local g, metrics, palette = self.geometry, Card.metrics, Card.palette
  local x, y = g.px(metrics.padding_x), g.px(metrics.padding_y)
  local width = math.max(0, self.panel.width - 2 * x)
  local mark = g.px(metrics.mark_side)
  local slot = self.has_favicon and mark or g.small_icon
  local reserved = math.min(width / 2, slot + g.px(metrics.project_gap + metrics.project_minimum))
  local available = width - reserved
  local status = context.connected and agent.status or "unknown"
  local word = status == "blocked" and (reasons[agent.blocked_reason] or "Needs input")
    or words[status]
    or ""
  local glyph = status == "blocked" and (blocked_glyphs[agent.blocked_reason] or "!")
    or glyphs[status]
    or ""
  if not context.connected then
    word, glyph = "offline", "?"
  end
  local state_text = status == "working"
      and (word .. " " .. AgentStatus.duration(agent.status_age_s))
    or status == "ready" and AgentStatus.age(agent.status_age_s)
    or word
  local ink = palette[status] or palette.overlay1
  self.state.color = ink
  self.state["font.pixelSize"] = g.small
  self.state.scale = 1 / g.scale
  self.state.text = state_text
  local text_width = self.state.implicitWidth / g.scale
  local glyph_width = glyph ~= "" and g.title_icon or 0
  local gap = g.px(metrics.gap)
  local glyph_space = glyph_width > 0 and glyph_width + gap or 0

  if glyph_space + text_width > available then
    state_text = word
    self.state.text = state_text
    text_width = self.state.implicitWidth / g.scale
  end
  if glyph_space + text_width > available then
    state_text, text_width = "", 0
  end

  local used = math.min(
    available,
    glyph_width + text_width + (glyph_width > 0 and text_width > 0 and gap or 0)
  )
  local show_state_icon = glyph_width > 0
  self.state_icon.visible = show_state_icon
  if show_state_icon then
    local side = math.min(glyph_width, used, g.small_row)
    self:glyph(
      self.state_icon,
      { text = glyph, pixels = g.title, color = ink },
      { x = x + width - used, y = y + (g.small_row - side) / 2, width = side, height = side }
    )
  end
  self:set_text(
    self.state,
    state_text,
    { x = x + width - text_width, y = y, width = text_width, height = g.small_row },
    g.small
  )

  local project_width = math.max(0, width - used - gap)
  local show_project = project_width >= slot
  self.folder.visible = show_project and not self.has_favicon
  self.project_icon.visible = show_project and self.has_favicon
  self.project.visible = show_project
  if show_project then
    local icon = self.has_favicon and self.project_icon or self.folder
    local side = self.has_favicon and math.min(mark, g.small_row) or math.min(slot, g.small_row)
    if not self.has_favicon then
      self:glyph(
        icon,
        { text = "\239\129\187", pixels = g.small, color = palette.subtext0 },
        { x = x, y = y + (g.small_row - side) / 2, width = side, height = side }
      )
    else
      icon.x, icon.y = x + (slot - side) / 2, y + (g.small_row - side) / 2
      icon.width, icon.height = side, side
    end
    local project_gap = g.px(metrics.project_gap)
    local project = agent.workspace_label
      .. (context.coordinators[agent.pane] and " · coordinator" or "")
    self.project.color = palette.subtext0
    self:set_text(self.project, project, {
      x = x + slot + project_gap,
      y = y,
      width = math.max(0, project_width - slot - project_gap),
      height = g.small_row,
    }, g.small)
  end

  y = y + g.small_row + g.px(metrics.title_gap)
  self.title.color = palette.text
  self:set_text(
    self.title,
    agent.title ~= "" and agent.title or agent.name ~= "" and agent.name or "Agent",
    { x = x, y = y, width = width, height = g.title_row },
    g.title
  )
  y = y + g.title_row + g.px(metrics.detail_gap)
  local detail_width = width
  local show_provider = mark <= width
  local builtin_provider = providers[agent.provider] == true
  self.provider.visible = show_provider and builtin_provider
  self.custom_provider.visible = show_provider and not builtin_provider
  if show_provider then
    local box =
      { x = x + width - mark, y = y + (g.small_row - mark) / 2, width = mark, height = mark }
    if builtin_provider then
      local side = math.max(
        metrics.minimum_artwork,
        math.min(metrics.maximum_artwork, round(metrics.artwork_side * g.ratio))
      )
      source(
        self.provider,
        string.format(
          "image://artwork/provider/%s/%s/%d",
          agent.provider,
          palette.text:sub(-6),
          side
        )
      )
      self.provider.x, self.provider.y = box.x, box.y
      self.provider.width, self.provider.height = box.width, box.height
    else
      self.custom_provider.color = palette.subtext0
      self.custom_provider.horizontalAlignment = "AlignHCenter"
      self:set_text(
        self.custom_provider,
        agent.icon ~= "" and agent.icon or Card.unknown_provider_glyph,
        box,
        g.small
      )
    end
    detail_width = math.max(0, width - mark - gap)
  end

  local branch = agent.workspace_kind ~= "worktree" and context.branches[agent.workspace] or ""
  self.detail.color = palette.overlay1
  self:set_text(
    self.detail,
    agent.status == "working" and agent.last_event or branch,
    { x = x, y = y, width = detail_width, height = g.small_row },
    g.small
  )
  self.panel.height = y + g.small_row + g.px(metrics.padding_y)
  self.panel.radius = g.px(metrics.radius)
  self:paint()
  self:pulse(self.frame or 0)
end

function Card:paint()
  local selected = self.selected and self.context.connected
  self.panel.color = selected and Card.palette.surface0
    or self.hovered and Card.palette.surface1
    or "transparent"
  self.panel["border.color"] = selected and Card.palette.surface1 or "transparent"
  self.panel["border.width"] = selected and 1 / self.geometry.scale or 0
end

function Card:set_selected(selected)
  self.selected = selected
  if self.agent then
    self:paint()
  end
end

function Card:set_hovered(hovered)
  self.hovered = hovered
  if self.agent then
    self:paint()
  end
end

function Card:pulse(frame)
  self.frame = frame % 256
  self.state_icon.opacity = self.agent
      and self.agent.status == "working"
      and self.context.connected
      and AgentStatus.pulse(self.frame)
    or 1
end

function Card:release()
  if self.cancel_icon then
    self.cancel_icon()
    self.cancel_icon = nil
  end
  self.favicon_url = nil
  self.agent, self.context = nil, nil
  self.hovered, self.selected = false, false
end

return Card
