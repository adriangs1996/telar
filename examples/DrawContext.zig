const State = @import("State.zig");
const BufferType = @import("telar-core").Buffer;
const RectType = @import("telar-core").Rect;
const DrawContext = @This();

state: *State,
buffer: *BufferType,
area: RectType,
