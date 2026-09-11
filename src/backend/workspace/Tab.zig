const Tab = @This();
const source_namespace = @import("workspace_support.zig");
id: source_namespace.schema.TabId,
label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
label_len: u8 = 0,

pub fn init(id: source_namespace.schema.TabId, label: []const u8) !Tab {
    var tab: Tab = .{ .id = id };
    try tab.rename(label);
    return tab;
}

pub fn rename(tab: *Tab, label: []const u8) !void {
    if (label.len == 0 or label.len > tab.label.len) {
        return error.InvalidTabLabel;
    }

    @memcpy(tab.label[0..label.len], label);
    tab.label_len = @intCast(label.len);
}

pub fn labelSlice(tab: *const Tab) []const u8 {
    return tab.label[0..tab.label_len];
}
