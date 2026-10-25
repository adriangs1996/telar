-- Run with LuaJIT from services/desktop-mode: luajit tests/agent_card.lua
local directory = arg[1] or "ui"
local theme = assert(loadfile(directory .. "/themes/dark.lua"))()
local cancelled = 0
local active = true
local function object(properties, kind)
  properties.kind = kind
  return setmetatable(properties, {
    __index = function(self, key)
      if key == "visible" then
        return active and self.requested_visible ~= false
      end
      if key == "implicitWidth" then
        if self.kind == "image" then
          return 1
        end
        local _, count = (self.text or ""):gsub("[^\128-\191]", "")
        return count * (self["font.pixelSize"] or 11) * 0.55
      end
      if key == "implicitHeight" then
        return (self["font.pixelSize"] or 11) * 1.3
      end
    end,
    __newindex = function(self, key, value)
      rawset(self, key == "visible" and "requested_visible" or key, value)
    end,
  })
end
local ui = {
  surface = { scale = 1 },
  create = function(_, _, properties)
    return object(properties, "rectangle")
  end,
  text = function(properties)
    return object(properties, "text")
  end,
  image = function(properties)
    return object(properties, "image")
  end,
  after = function()
    return function()
      cancelled = cancelled + 1
    end
  end,
}
local modules = { ["telar.ui"] = ui, ["telar.theme"] = theme }
local environment = setmetatable({
  require = function(name)
    return assert(modules[name], name)
  end,
}, { __index = _G })
modules.agent_status = setfenv(assert(loadfile(directory .. "/agent_status.lua")), environment)()
local Card = setfenv(assert(loadfile(directory .. "/sidebar/card.lua")), environment)()
local context = {
  connected = true,
  branches = { first = "main", second = "feature" },
  paths = {},
  coordinators = {},
}
local agent = {
  pane = "11",
  workspace = "first",
  workspace_kind = "workspace",
  workspace_label = "project",
  title = "Session title",
  name = "Codex",
  provider = "codex",
  icon = "",
  status = "working",
  status_age_s = 7,
  blocked_reason = "none",
  last_event = "Running tests",
}
local card = Card.new({})
active = false
local height = card:fill(agent, context, 300)
assert(card.state_icon.source and card.provider.source)
active = true
assert(height == 69)
assert(card.project.text == "project" and card.state.text == "Working 7s")
assert(card.title.text == "Session title" and card.detail.text == "Running tests")
assert(card.project.y < card.title.y and card.title.y < card.detail.y)
assert(card.title["font.weight"] == 400 and card.title["font.family"] == "IBM Plex Sans")
assert(card.title.renderType == "NativeRendering")
assert(card.provider.visible and card.provider.opacity == 0.6)

agent.plan = { done = 2, total = 5, step = "A different plan step" }
agent.final_message = "A previous answer"
assert(card:fill(agent, context, 300) == height)
assert(card.detail.text == "Running tests")
agent.last_event = ""
assert(card:fill(agent, context, 300) == height and card.detail.text == "")

agent.status = "done"
agent.workspace = "second"
card:fill(agent, context, 300)
assert(card.detail.text == "feature" and card.state.text == "Done")
context.branches.second = "renamed-branch"
card:fill(agent, context, 300)
assert(card.detail.text == "renamed-branch")
agent.workspace_kind = "worktree"
card:fill(agent, context, 300)
assert(card.detail.text == "")
agent.workspace_kind = "workspace"

agent.status = "blocked"
for reason, word in pairs({
  permission = "Approval",
  question = "Question",
  plan = "Review plan",
  other = "Needs input",
}) do
  agent.blocked_reason = reason
  card:fill(agent, context, 300)
  assert(card.state.text == word and card.state_icon.visible)
end

agent.status = "ready"
card:fill(agent, context, 300)
assert(card.state.text == "now" and not card.state_icon.visible)
agent.status_age_s = 65
card:fill(agent, context, 300)
assert(card.state.text == "1m")
agent.status, agent.status_age_s = "working", 59
card:fill(agent, context, 300)
assert(card.state.text == "Working 59s")
card:fill(agent, context, 125)
assert(card.state.text == "Working")
card:fill(agent, context, 90)
assert(card.state.text == "" and card.state_icon.visible)
card:fill(agent, context, 30)
assert(card.title.width >= 0 and card.detail.width >= 0 and card.panel.height == height)

card:fill(agent, context, 300)
card:pulse(0)
assert(card.state_icon.opacity == 1)
card:pulse(8)
assert(card.state_icon.opacity < 1 and card.state.text == "Working 59s")
assert(card.state.opacity == nil and card.title.opacity == nil)
card:set_selected(true)
assert(card.panel.color == Card.palette.surface0 and card.panel["border.width"] == 1)
card:set_hovered(true)
assert(card.panel.color == Card.palette.surface0)
card:set_selected(false)
assert(card.panel.color == Card.palette.surface1)
card:set_hovered(false)
context.connected = false
card:set_selected(true)
card:fill(agent, context, 300)
assert(card.state.text == "offline" and card.panel.color == "transparent")

context.connected = true
context.coordinators[agent.pane] = true
agent.title = ""
card:fill(agent, context, 300)
assert(card.project.text == "project · coordinator" and card.title.text == "Codex")
agent.provider, agent.icon = "custom", "λ"
card:fill(agent, context, 300)
assert(card.custom_provider.visible and not card.provider.visible)
assert(card.custom_provider.text == "λ")
local original_padding = Card.metrics.padding_x
Card.metrics.padding_x = 18
card:fill(agent, context, 300)
assert(card.title.x == 18)
Card.metrics.padding_x = original_padding
ui.surface.scale = 2
card:fill(agent, context, 300)
assert(card.panel.height == 68 and card.title.scale == 0.5)
assert(card.panel["border.width"] == 0.5)

context.paths.second = "/tmp/project"
card:fill(agent, context, 300)
assert(card.cancel_icon)
card:release()
assert(cancelled > 0 and card.favicon_url == nil and card.agent == nil)
print(
  "Agent cards: rows, activity, branches, status reasons, clipping, pulse, focus, DPI and Lua customization passed"
)
