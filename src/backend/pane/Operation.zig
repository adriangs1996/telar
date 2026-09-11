const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const vt = @import("ghostty-vt");
const Options = @import("Options.zig");
const Operation = @This();

buffer: *BufferType,
area: RectType,
terminal: *const vt.Terminal,
state: *vt.RenderState,
options: Options,
