-- The default pane header, drawn with built-in pieces.
local ui = require("telar").ui

return {
  pane_header = function(ctx, pane)
    return ui.row({
      gap = 8, padding = { 0, 8 }, align = "center",
      ui.builtin("pane_mark"),
      ui.builtin("pane_program"),
      ui.builtin({ name = "pane_context", grow = 1 }),
      ui.builtin("pane_progress"),
      ui.builtin("pane_status"),
      ui.builtin("pane_actions"),
    })
  end,
}
