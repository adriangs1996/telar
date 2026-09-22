const core = @import("telar-core");
const vt = @import("ghostty-vt");
const Options = @import("Options.zig");
const Operation = @This();

buffer: *core.Buffer,
area: core.Rect,
terminal: *const vt.Terminal,
state: *vt.RenderState,
options: Options,
