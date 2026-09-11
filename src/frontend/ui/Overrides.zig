/// Optional color values map directly to future user configuration keys.
/// `.default` means that the host terminal supplies the color.
const Overrides = @This();
const ui = @import("telar-core").ui;
accent: ?ui.Color = null,
panel_bg: ?ui.Color = null,
surface0: ?ui.Color = null,
surface1: ?ui.Color = null,
surface_dim: ?ui.Color = null,
overlay0: ?ui.Color = null,
overlay1: ?ui.Color = null,
text: ?ui.Color = null,
subtext0: ?ui.Color = null,
mauve: ?ui.Color = null,
green: ?ui.Color = null,
yellow: ?ui.Color = null,
red: ?ui.Color = null,
blue: ?ui.Color = null,
teal: ?ui.Color = null,
peach: ?ui.Color = null,
