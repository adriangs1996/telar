-- The default tab, drawn with built-in pieces: copy it and change what you need.
local ui = require("telar").ui

return {
  tab = function(ctx, tab)
    return ui.row({
      gap = 12, padding = { 0, 14 }, align = "center",
      ui.builtin("tab_cards"),
      ui.builtin({ name = "tab_title", grow = 1 }),
      ui.builtin("tab_path"),
      ui.builtin("tab_activity"),
    })
  end,
}
