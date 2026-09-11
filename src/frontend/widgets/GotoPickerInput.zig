const goto_picker = @import("goto_picker.zig");
const Row = @import("Row.zig");
const Input = @This();

title: []const u8,
field: *goto_picker.Field,
rows: []const Row,
total: u16,
/// Short status shown in the bottom border, e.g. the active scope.
hint: []const u8 = "",
/// True when a pixel-aligned frame already surrounds the modal, so the
/// cell border must not be drawn on top of it.
graphical_frame: bool = false,
