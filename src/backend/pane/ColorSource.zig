const vt = @import("ghostty-vt");
const ColorSource = @This();

terminal: *const vt.Terminal,
colors: vt.RenderState.Colors,
