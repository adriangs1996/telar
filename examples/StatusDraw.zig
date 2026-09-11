const RectType = @import("telar-core").Rect;
const Task = @import("Task.zig");
const ColorType = @import("telar-core").Color;
const StatusDraw = @This();

area: RectType,
y: u16,
task: Task,
background: ColorType,
