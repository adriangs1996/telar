//! Optional synchronous decorations; ownership stays with the embedding view.
const Canvas = @import("Canvas.zig");
const Row = @import("DiffRow.zig");

context: *anyopaque,
row: *const fn (*anyopaque, *Canvas, Row) anyerror!void,
after: *const fn (*anyopaque, *Canvas, Row) anyerror!f32,
