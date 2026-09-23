//! One client generation holds the geometry lease of a workspace: only it
//! may resize the workspace's PTYs. Spectators crop or letterbox instead.
//! The lease is a column of the workspace table, so a proposed workspace
//! can hold it before its first pane launch commits.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const ClientKey = @import("../history/ClientKey.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const resync_required = @import("resync_required.zig");
const terminal_colors = @import("terminal_colors.zig");

/// Takes the lease when the workspace has none, or confirms the caller
/// already holds it. Returns false when another client holds it or the
/// workspace does not exist. Taking the lease applies the holder's colors.
///
/// ```zig
/// if (!geometry_lease.acquire(model, session.key, workspace)) return error.GeometryUnavailable;
/// ```
pub fn acquire(model: *RuntimeModel, key: ClientKey, workspace: core.WorkspaceLocation) bool {
    const slot = model.workspaces.reservedSlotOf(workspace) orelse return false;
    if (model.workspaces.lease[slot]) |holder| {
        return std.meta.eql(holder, key);
    }

    model.workspaces.lease[slot] = key;
    terminal_colors.apply(model, workspace, key);
    return true;
}

/// Reads the holder without taking an unowned lease.
/// Example: `const holder = geometry_lease.owner(model, workspace) orelse return;`.
pub fn owner(model: *const RuntimeModel, workspace: core.WorkspaceLocation) ?ClientKey {
    const slot = model.workspaces.reservedSlotOf(workspace) orelse return null;
    return model.workspaces.lease[slot];
}

/// Releases one workspace's lease held by `key` and asks the other
/// observers to resync so one of them re-offers its geometry.
///
/// ```zig
/// geometry_lease.release(model, session.key, workspace);
/// ```
pub fn release(model: *RuntimeModel, key: ClientKey, workspace: core.WorkspaceLocation) void {
    const slot = model.workspaces.reservedSlotOf(workspace) orelse return;
    const holder = model.workspaces.lease[slot] orelse return;
    if (!std.meta.eql(holder, key)) {
        return;
    }

    model.workspaces.lease[slot] = null;
    resync_required.notify(model, .{ .origin = key, .workspace = workspace });
}

/// Releases every lease a departing client held.
///
/// ```zig
/// geometry_lease.releaseAll(model, session.key);
/// ```
pub fn releaseAll(model: *RuntimeModel, key: ClientKey) void {
    var rows = model.workspaces.reserved.iterator(.{});
    while (rows.next()) |slot| {
        const holder = model.workspaces.lease[slot] orelse continue;
        if (!std.meta.eql(holder, key)) {
            continue;
        }

        model.workspaces.lease[slot] = null;
        // The lease is free but the runtime does not know any surviving
        // client's size. Resync the observers so one re-offers its
        // geometry and takes the lease over; without this the pane keeps
        // the departed client's size until an unrelated resize.
        resync_required.notify(model, .{ .origin = key, .workspace = .{ .workspace = model.workspaces.id[slot] } });
    }
}

test "a workspace geometry lease is exclusive to one client generation" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.workspaces = .{};
    defer model.workspaces.deinit(std.testing.allocator);

    const location = try model.workspaces.insert(std.testing.allocator, "/work/telar", null);
    const workspace = location.workspace;
    const holder: ClientKey = .{ .id = 3, .generation = 4 };
    const stale_holder: ClientKey = .{ .id = 3, .generation = 3 };

    try std.testing.expect(acquire(model, holder, workspace));
    try std.testing.expect(acquire(model, holder, workspace));
    try std.testing.expect(!acquire(model, stale_holder, workspace));

    release(model, holder, workspace);

    try std.testing.expect(acquire(model, stale_holder, workspace));
}

test "a proposed workspace holds its lease until rollback releases the row" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.workspaces = .{};
    defer model.workspaces.deinit(std.testing.allocator);

    const holder: ClientKey = .{ .id = 1, .generation = 1 };
    const slot = try model.workspaces.propose(std.testing.allocator, "/work/proposed", null);
    const workspace: core.WorkspaceLocation = .{ .workspace = model.workspaces.id[slot] };

    try std.testing.expect(acquire(model, holder, workspace));
    try std.testing.expectEqualDeep(holder, owner(model, workspace).?);
    model.workspaces.rollback(std.testing.allocator, slot);
    try std.testing.expect(owner(model, workspace) == null);
    try std.testing.expect(!acquire(model, holder, workspace));
}

test "leases exist only for workspaces the table holds" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.workspaces = .{};

    const holder: ClientKey = .{ .id = 1, .generation = 1 };
    const missing: core.WorkspaceLocation = .{ .workspace = @enumFromInt(Workspaces.capacity + 1) };
    try std.testing.expect(!acquire(model, holder, missing));
}
