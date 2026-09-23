const core = @import("telar-core");
const OverrideType = @import("../pty/Override.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const std = @import("std");
/// Fixed storage for the environment variables that let a child find the
/// runtime and name its own pane. `TELAR_SOCKET` stays absent on purpose: a
/// nested runtime must not inherit the outer listener as its own.
const PaneOverrides = @This();

pub const count = 6;

pane_id: [20]u8 = undefined,
pane_generation: [20]u8 = undefined,
workspace_id: [20]u8 = undefined,
tab_id: [20]u8 = undefined,
entries: [count]OverrideType = undefined,

/// Formats the identity into owned decimal storage and returns the
/// override slice borrowed from `overrides`.
///
/// ```zig
/// var overrides: PaneOverrides = .{};
/// const entries = overrides.build(key, location, socket_path, executable_path);
/// ```
pub fn build(self: *PaneOverrides, key: PaneKey, location: core.TabLocation, socket_path: []const u8, executable_path: []const u8) []const OverrideType {
    const pane_id = std.fmt.bufPrint(&self.pane_id, "{d}", .{core.raw(key.id)}) catch unreachable;
    const pane_generation = std.fmt.bufPrint(&self.pane_generation, "{d}", .{key.generation}) catch unreachable;
    const workspace_id = std.fmt.bufPrint(&self.workspace_id, "{d}", .{core.raw(location.workspace.workspace)}) catch unreachable;
    const tab_id = std.fmt.bufPrint(&self.tab_id, "{d}", .{core.raw(location.tab_id)}) catch unreachable;
    self.entries = .{
        .{ .name = "TELAR_SOCKET_PATH", .value = socket_path },
        .{ .name = "TELAR_PANE_ID", .value = pane_id },
        .{ .name = "TELAR_PANE_GENERATION", .value = pane_generation },
        .{ .name = "TELAR_WORKSPACE_ID", .value = workspace_id },
        .{ .name = "TELAR_TAB_ID", .value = tab_id },
        .{ .name = "TELAR_BIN_PATH", .value = executable_path },
    };
    return &self.entries;
}
