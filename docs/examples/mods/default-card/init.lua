-- The default activity card, drawn with built-in pieces.
local ui = require("telar").ui

return {
  agent_card = function(ctx, agent)
    return ui.column({
      gap = 4, padding = 8,
      ui.row({ gap = 8, align = "center", ui.builtin("agent_mark"), ui.builtin({ name = "agent_title", grow = 1 }) }),
      ui.row({ gap = 8, align = "center", ui.builtin({ name = "agent_project", grow = 1 }), ui.builtin("agent_status") }),
    })
  end,
}
