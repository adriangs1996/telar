const core = @import("telar-core");
/// Optional color values map directly to future user configuration keys.
/// `.default` means that the host terminal supplies the color.
const Overrides = @This();

accent: ?core.Color = null,
panel_bg: ?core.Color = null,
surface0: ?core.Color = null,
surface1: ?core.Color = null,
surface_dim: ?core.Color = null,
overlay0: ?core.Color = null,
overlay1: ?core.Color = null,
text: ?core.Color = null,
subtext0: ?core.Color = null,
mauve: ?core.Color = null,
green: ?core.Color = null,
yellow: ?core.Color = null,
red: ?core.Color = null,
blue: ?core.Color = null,
teal: ?core.Color = null,
peach: ?core.Color = null,
