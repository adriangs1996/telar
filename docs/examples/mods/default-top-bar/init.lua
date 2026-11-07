-- The default top bar, drawn with built-in pieces. The window buttons keep
-- their place to the left of whatever this returns.
local ui = require("telar").ui

return {
  top_bar = function(ctx, bar)
    return ui.row({
      gap = 8, align = "center",
      ui.builtin("sidebar_toggle"),
      ui.builtin("workspace_identity"),
      ui.builtin({ name = "tabs", grow = 1 }),
      ui.builtin("project_switcher"),
      ui.builtin("palette_button"),
      ui.builtin("new_tab"),
    })
  end,
}
