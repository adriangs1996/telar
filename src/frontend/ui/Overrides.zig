const ColorType = @import("telar-core").Color;
/// Optional color values map directly to future user configuration keys.
/// `.default` means that the host terminal supplies the color.
const Overrides = @This();

accent: ?ColorType = null,
panel_bg: ?ColorType = null,
surface0: ?ColorType = null,
surface1: ?ColorType = null,
surface_dim: ?ColorType = null,
overlay0: ?ColorType = null,
overlay1: ?ColorType = null,
text: ?ColorType = null,
subtext0: ?ColorType = null,
mauve: ?ColorType = null,
green: ?ColorType = null,
yellow: ?ColorType = null,
red: ?ColorType = null,
blue: ?ColorType = null,
teal: ?ColorType = null,
peach: ?ColorType = null,
