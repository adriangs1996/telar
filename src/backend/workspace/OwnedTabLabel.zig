const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const OwnedTabLabel = @This();

bytes: [max_tab_label_bytes_module]u8 = undefined,
len: u8,

pub fn init(label: []const u8) !OwnedTabLabel {
    if (label.len == 0 or label.len > max_tab_label_bytes_module) {
        return error.InvalidTabLabel;
    }

    var owned: OwnedTabLabel = .{ .len = @intCast(label.len) };
    @memcpy(owned.bytes[0..label.len], label);
    return owned;
}

pub fn slice(label: *const OwnedTabLabel) []const u8 {
    return label.bytes[0..label.len];
}
