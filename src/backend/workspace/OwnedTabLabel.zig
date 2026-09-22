const core = @import("telar-core");
const OwnedTabLabel = @This();

bytes: [core.max_tab_label_bytes]u8 = undefined,
len: u8,

pub fn init(label: []const u8) !OwnedTabLabel {
    if (label.len > core.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedTabLabel = .{ .len = @intCast(label.len) };
    @memcpy(owned.bytes[0..label.len], label);
    return owned;
}

pub fn slice(label: *const OwnedTabLabel) []const u8 {
    return label.bytes[0..label.len];
}
