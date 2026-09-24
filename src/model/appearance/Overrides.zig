const cellgrid = @import("cellgrid");
/// Optional color values map directly to future user configuration keys.
/// `.default` means that the host terminal supplies the color.
const Overrides = @This();

accent: ?cellgrid.Color = null,
panel_bg: ?cellgrid.Color = null,
surface0: ?cellgrid.Color = null,
surface1: ?cellgrid.Color = null,
surface_dim: ?cellgrid.Color = null,
overlay0: ?cellgrid.Color = null,
overlay1: ?cellgrid.Color = null,
text: ?cellgrid.Color = null,
subtext0: ?cellgrid.Color = null,
mauve: ?cellgrid.Color = null,
green: ?cellgrid.Color = null,
yellow: ?cellgrid.Color = null,
red: ?cellgrid.Color = null,
blue: ?cellgrid.Color = null,
teal: ?cellgrid.Color = null,
peach: ?cellgrid.Color = null,
