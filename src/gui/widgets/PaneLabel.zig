const std = @import("std");
const core = @import("telar-core");
const PaneLabel = @This();

bytes: [core.max_foreground_name_bytes + 32]u8 = undefined,
len: usize = 0,

pub fn init(name: []const u8, index: u16) PaneLabel {
    var label: PaneLabel = .{};
    const written = std.fmt.bufPrint(&label.bytes, " {d} {s} ", .{ index, if (name.len == 0) "shell" else name }) catch unreachable;
    label.len = written.len;
    return label;
}

pub fn text(self: *const PaneLabel) []const u8 {
    return self.bytes[0..self.len];
}

pub fn width(self: *const PaneLabel) u16 {
    return core.measure(self.text());
}
