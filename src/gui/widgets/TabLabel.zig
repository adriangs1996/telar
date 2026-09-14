const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const TabLabel = @This();

bytes: [core.max_tab_label_bytes + 32]u8 = undefined,
len: usize = 0,

pub fn init(tab: *const client.Tab, index: usize) TabLabel {
    var label: TabLabel = .{};
    const written = std.fmt.bufPrint(&label.bytes, " {d}:{s}{s} ", .{ index + 1, tab.labelSlice(), if (tab.model.layout.isFullscreen()) " ⛶" else "" }) catch unreachable;
    label.len = written.len;
    return label;
}

pub fn text(label: *const TabLabel) []const u8 {
    return label.bytes[0..label.len];
}

pub fn width(label: *const TabLabel) u16 {
    return core.measure(label.text());
}
