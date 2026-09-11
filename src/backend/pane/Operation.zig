const Operation = @This();
const source_namespace = @import("blit.zig");
const vt = @import("ghostty-vt");
const Options = @import("Options.zig");
buffer: *source_namespace.ui.Buffer,
area: source_namespace.ui.Rect,
terminal: *const vt.Terminal,
state: *vt.RenderState,
options: Options,
