-- The default bottom bar: the three `bars.bottom` sources as built-in pieces.
-- Prefix mode, the TLS badge and diagnostics stay native.
local ui = require("telar").ui

return {
  bottom_bar = function(ctx, bar)
    return ui.row({
      gap = 24, padding = { 0, 8 }, align = "center",
      ui.builtin("bar_left"),
      ui.builtin({ name = "bar_center", grow = 1 }),
      ui.builtin("bar_right"),
    })
  end,
}
