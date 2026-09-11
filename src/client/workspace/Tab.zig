const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const MultiplexerModel = @import("MultiplexerModel.zig");
const std = @import("std");
const TabInit = @import("TabInit.zig");
const Tab = @This();

location: TabLocationType,
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8 = 0,
model: MultiplexerModel,
snapshot_loaded: bool = false,
restore_display_order: bool = false,

pub fn init(gpa: std.mem.Allocator, input: TabInit) Tab {
    var tab: Tab = .{
        .location = input.location,
        .model = .init(gpa),
    };

    tab.model.setPaneGaps(input.pane_gaps);
    tab.setLabel(input.label);

    return tab;
}

pub fn deinit(tab: *Tab) void {
    tab.model.deinit();
}

pub fn labelSlice(tab: *const Tab) []const u8 {
    return tab.label[0..tab.label_len];
}

pub fn setLabel(tab: *Tab, label: []const u8) void {
    std.debug.assert(label.len != 0 and label.len <= tab.label.len);
    @memcpy(tab.label[0..label.len], label);
    tab.label_len = @intCast(label.len);
}
