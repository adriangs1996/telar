const StatusDraw = @This();
const source_namespace = @import("sidebar.zig");
const Task = @import("Task.zig");
area: source_namespace.ui.Rect,
y: u16,
task: Task,
background: source_namespace.ui.Color,
