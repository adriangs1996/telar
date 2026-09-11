/// Fixed storage for the environment variables that let a child find the
/// runtime and name its own pane. `TELAR_SOCKET` stays absent on purpose: a
/// nested runtime must not inherit the outer listener as its own.
const PaneOverrides = @This();
const pty = @import("../../pty/root.zig");
const PaneIdentity = @import("PaneIdentity.zig");
const std = @import("std");
const source_namespace = @import("pane_launcher.zig");
pub const count = 6;

pane_id: [20]u8 = undefined,
pane_generation: [20]u8 = undefined,
workspace_id: [20]u8 = undefined,
tab_id: [20]u8 = undefined,
entries: [count]pty.ChildEnvironment.Override = undefined,

/// Formats the identity into owned decimal storage and returns the
/// override slice borrowed from `overrides`.
///
/// ```zig
/// var overrides: PaneOverrides = .{};
/// const entries = overrides.build(.{ .key = key, .location = location, .socket_path = path, .executable_path = executable });
/// ```
pub fn build(overrides: *PaneOverrides, identity: PaneIdentity) []const pty.ChildEnvironment.Override {
    const pane_id = std.fmt.bufPrint(&overrides.pane_id, "{d}", .{source_namespace.schema.id.raw(identity.key.id)}) catch unreachable;
    const pane_generation = std.fmt.bufPrint(&overrides.pane_generation, "{d}", .{identity.key.generation}) catch unreachable;
    const workspace_id = std.fmt.bufPrint(&overrides.workspace_id, "{d}", .{source_namespace.schema.id.raw(identity.location.workspace.workspace)}) catch unreachable;
    const tab_id = std.fmt.bufPrint(&overrides.tab_id, "{d}", .{source_namespace.schema.id.raw(identity.location.tab_id)}) catch unreachable;
    overrides.entries = .{
        .{ .name = "TELAR_SOCKET_PATH", .value = identity.socket_path },
        .{ .name = "TELAR_PANE_ID", .value = pane_id },
        .{ .name = "TELAR_PANE_GENERATION", .value = pane_generation },
        .{ .name = "TELAR_WORKSPACE_ID", .value = workspace_id },
        .{ .name = "TELAR_TAB_ID", .value = tab_id },
        .{ .name = "TELAR_BIN_PATH", .value = identity.executable_path },
    };
    return &overrides.entries;
}
