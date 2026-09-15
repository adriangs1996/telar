const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const MultiplexerModel = @import("MultiplexerModel.zig");
const std = @import("std");
const TabInit = @import("TabInit.zig");
const IconType = @import("../layout/icons.zig").Icon;
const Tab = @This();

location: TabLocationType,
/// An empty canonical label follows the focused foreground application.
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

/// Resolves the visible label without storing transient foreground state.
/// Example: const title = tab.labelSlice();
pub fn labelSlice(tab: *const Tab) []const u8 {
    if (!tab.isAutomatic()) {
        return tab.canonicalLabel();
    }

    const pane = tab.model.focusedPaneConst() orelse return "shell";
    return pane.applicationLabel();
}

/// Returns the runtime label, including the empty automatic-name sentinel.
/// Example: const unchanged = std.mem.eql(u8, tab.canonicalLabel(), snapshot.label);
pub fn canonicalLabel(tab: *const Tab) []const u8 {
    return tab.label[0..tab.label_len];
}

pub fn isAutomatic(tab: *const Tab) bool {
    return tab.label_len == 0;
}

/// Resolves automatic tab artwork from the same pane as its display label.
/// Example: if (tab.labelIcon()) |icon| draw(icon);
pub fn labelIcon(tab: *const Tab) ?IconType {
    if (!tab.isAutomatic()) {
        return null;
    }

    const pane = tab.model.focusedPaneConst() orelse return .app_terminal;
    return pane.applicationIcon();
}

pub fn setLabel(tab: *Tab, label: []const u8) void {
    std.debug.assert(label.len <= tab.label.len);
    @memcpy(tab.label[0..label.len], label);
    tab.label_len = @intCast(label.len);
}
