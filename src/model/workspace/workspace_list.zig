//! Bounded replica of the runtime's open-workspace list.
//!
//! The runtime owns workspace truth. One disposable client model keeps this
//! fixed-capacity value for navigation and presentation. Newer revisions
//! replace it atomically; stale or oversized snapshots preserve the last
//! usable value.

const WorkspaceListCollapse = @import("../state/WorkspaceListCollapse.zig");
const ClientModel = @import("../state/ClientModel.zig");
const core = @import("telar-core");
const WorkspaceListSnapshot = @import("WorkspaceListSnapshot.zig");
const EntryInput = @import("EntryInput.zig");
const std = @import("std");

/// Names arrive whole; views clip them to the room they have.
pub const max_name_bytes = core.max_workspace_name_bytes;
/// Bytes of path the pool holds for each workspace on average; paths of a
/// project or worktree checkout run well under it.
const average_path_bytes = 512;
/// One shared pool for every stored path. Paths stay whole so the replica
/// never exposes a fabricated location: a list whose paths do not all fit
/// keeps the entries before the first that does not and counts the rest in
/// `dropped`.
pub const path_pool_size = core.max_workspace_list_entries * average_path_bytes;
pub const path_pool_limit = core.Limit.declare("workspace_list.path_pool_size", "path bytes", path_pool_size);

test "replacement rejects stale revisions and copies into fixed storage" {
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    try std.testing.expect(!try snapshot.replace(.{ .revision = 0, .entries = &entries }));
    try std.testing.expect(try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 2, .entries = &entries }));
    try std.testing.expectEqual(@as(usize, 2), snapshot.count);
    try std.testing.expectEqualStrings("telar", snapshot.nameAt(0));
    try std.testing.expectEqualStrings("/work/api", snapshot.pathAt(1));
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(1)), snapshot.workspaceAtPosition(0).?);
    try std.testing.expectEqual(@as(core.WorkspaceId, @enumFromInt(2)), snapshot.workspaceAtPosition(1).?);
    try std.testing.expect(snapshot.workspaceAtPosition(2) == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.indexOf(@enumFromInt(2)).?);
    try std.testing.expect(snapshot.indexOf(@enumFromInt(9)) == null);
}

test "a list whose paths overflow the pool keeps the entries that fit" {
    var snapshot: WorkspaceListSnapshot = .{};
    const large_path: [core.max_cwd_bytes]u8 = @splat('x');
    const fitting = path_pool_size / large_path.len;
    var oversized: [fitting + 2]EntryInput = undefined;
    for (&oversized, 1..) |*entry, workspace| {
        entry.* = .{ .workspace = @enumFromInt(workspace), .name = "long", .path = &large_path, .tab_count = 1 };
    }

    try std.testing.expect(try snapshot.replace(.{
        .revision = 2,
        .entries = &oversized,
    }));
    try std.testing.expectEqual(@as(u64, 2), snapshot.revision);
    try std.testing.expectEqual(fitting, snapshot.count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.dropped);
    try std.testing.expectEqualStrings(&large_path, snapshot.pathAt(fitting - 1));
}

test "duplicate workspace ids are rejected" {
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(1), .name = "b", .path = "/b", .tab_count = 1 },
    };

    try std.testing.expectError(
        error.DuplicateWorkspace,
        snapshot.replace(.{ .revision = 1, .entries = &entries }),
    );
}

test "names are stored whole up to the wire bound" {
    var snapshot: WorkspaceListSnapshot = .{};
    const name: [core.max_workspace_name_bytes]u8 = @splat('n');
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = &name, .path = "/work", .tab_count = 1 },
    };

    try std.testing.expect(try snapshot.replace(.{ .revision = 1, .entries = &entries }));
    try std.testing.expectEqualStrings(&name, snapshot.nameAt(0));
}

/// Commits an explicit workspace-list collapse preference. Repeated
/// values preserve the chrome revision.
///
/// ```zig
/// const change = workspace_list.setCollapsed(model, true) orelse return;
/// ```
pub fn setCollapsed(model: *ClientModel, collapsed: bool) ?WorkspaceListCollapse {
    if (model.workspace_list_collapsed == collapsed) {
        return null;
    }

    model.workspace_list_collapsed = collapsed;
    model.chrome_revision +%= 1;

    return .{
        .collapsed = collapsed,
        .chrome_revision = model.chrome_revision,
    };
}

/// Toggles the workspace-list preference and advances only chrome.
///
/// ```zig
/// const change = workspace_list.toggle(model);
/// ```
pub fn toggle(model: *ClientModel) WorkspaceListCollapse {
    return setCollapsed(model, !model.workspace_list_collapsed).?;
}
