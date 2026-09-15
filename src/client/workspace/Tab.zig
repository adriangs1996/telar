const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const MultiplexerModel = @import("MultiplexerModel.zig");
const std = @import("std");
const TabInit = @import("TabInit.zig");
const IconType = @import("../layout/icons.zig").Icon;
const Tab = @This();
const PaneForeground = @import("telar-core").PaneForeground;
const PaneId = @import("telar-core").PaneId;
const max_foreground_name_bytes = @import("telar-core").max_foreground_name_bytes;

location: TabLocationType,
/// An empty canonical label follows the focused foreground application.
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8 = 0,
model: MultiplexerModel,
snapshot_loaded: bool = false,
restore_display_order: bool = false,
foreground_pane: PaneId = .invalid,
foreground_name: [max_foreground_name_bytes]u8 = undefined,
foreground_name_len: u8 = 0,

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

/// Resolves the visible label independently from the canonical manual label.
/// Example: const title = tab.labelSlice();
pub fn labelSlice(tab: *const Tab) []const u8 {
    if (!tab.isAutomatic()) {
        return tab.canonicalLabel();
    }

    return tab.applicationName();
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

    return IconType.forApplication(tab.applicationName());
}

fn applicationName(tab: *const Tab) []const u8 {
    if (tab.model.focusedPaneConst()) |pane| {
        if (pane.foregroundName().len != 0) {
            return pane.foregroundName();
        }

        if (pane.id != tab.foreground_pane) {
            return "shell";
        }
    }

    return if (tab.foreground_name_len == 0) "shell" else tab.foreground_name[0..tab.foreground_name_len];
}

/// Refreshes lightweight names using this client's focus before panes attach.
/// Example: `_ = tab.applyForegroundSnapshot(names, saved_focus);`.
pub fn applyForegroundSnapshot(tab: *Tab, names: []const PaneForeground, saved_focus: ?PaneId) bool {
    if (names.len == 0) {
        return false;
    }

    var previous: [max_tab_label_bytes_module]u8 = undefined;
    const previous_len = tab.labelSlice().len;
    @memcpy(previous[0..previous_len], tab.labelSlice());
    const focused = if (tab.snapshot_loaded) tab.model.layout.focused() else saved_focus orelse tab.model.layout.focused();
    var selected = names[0];
    for (names) |name| {
        if (focused != null and focused.? == name.pane_id) {
            selected = name;
        }
    }

    tab.foreground_pane = selected.pane_id;
    tab.storeForegroundName(selected.name);
    return !std.mem.eql(u8, previous[0..previous_len], tab.labelSlice());
}

/// Updates a detached tab's selected foreground without creating a pane model.
/// Example: `_ = tab.applyForegroundReport(report);`.
pub fn applyForegroundReport(tab: *Tab, report: PaneForeground) bool {
    if (report.pane_id != tab.foreground_pane or std.mem.eql(u8, report.name, tab.foreground_name[0..tab.foreground_name_len])) {
        return false;
    }

    tab.storeForegroundName(report.name);
    return tab.isAutomatic();
}

fn storeForegroundName(tab: *Tab, name: []const u8) void {
    std.debug.assert(name.len <= tab.foreground_name.len);
    @memcpy(tab.foreground_name[0..name.len], name);
    tab.foreground_name_len = @intCast(name.len);
}

pub fn setLabel(tab: *Tab, label: []const u8) void {
    std.debug.assert(label.len <= tab.label.len);
    @memcpy(tab.label[0..label.len], label);
    tab.label_len = @intCast(label.len);
}
