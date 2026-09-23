//! One client generation holds the geometry lease of a workspace: only it
//! may resize the workspace's PTYs. Spectators crop or letterbox instead.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const ClientKey = @import("../history/ClientKey.zig");
const resync_required = @import("resync_required.zig");
const terminal_colors = @import("terminal_colors.zig");
const state_support = @import("../workspace/state_support.zig");

/// Takes the lease when the workspace has none, or confirms the caller
/// already holds it. Returns false when another client holds it or every
/// lease slot is taken. Taking the lease applies the holder's colors.
///
/// ```zig
/// if (!geometry_lease.acquire(model, session.key, workspace)) return error.GeometryUnavailable;
/// ```
pub fn acquire(model: *RuntimeModel, key: ClientKey, workspace: core.WorkspaceLocation) bool {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.workspace, workspace)) {
            continue;
        }

        return std.meta.eql(lease.owner, key);
    }

    for (&model.geometry_leases) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = .{ .workspace = workspace, .owner = key };
        terminal_colors.apply(model, workspace, key);
        return true;
    }

    return false;
}

/// Reads the holder without taking an unowned lease.
/// Example: `const holder = geometry_lease.owner(model, workspace) orelse return;`.
pub fn owner(model: *const RuntimeModel, workspace: core.WorkspaceLocation) ?ClientKey {
    for (model.geometry_leases) |slot| {
        const lease = slot orelse continue;
        if (std.meta.eql(lease.workspace, workspace)) {
            return lease.owner;
        }
    }

    return null;
}

/// Releases one workspace's lease held by `key` and asks the other
/// observers to resync so one of them re-offers its geometry.
///
/// ```zig
/// geometry_lease.release(model, session.key, workspace);
/// ```
pub fn release(model: *RuntimeModel, key: ClientKey, workspace: core.WorkspaceLocation) void {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;
        if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace)) {
            slot.* = null;
            resync_required.notify(model, .{ .origin = key, .workspace = workspace });
        }
    }
}

/// Releases every lease a departing client held.
///
/// ```zig
/// geometry_lease.releaseAll(model, session.key);
/// ```
pub fn releaseAll(model: *RuntimeModel, key: ClientKey) void {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.owner, key)) {
            continue;
        }

        slot.* = null;
        // The lease is free but the runtime does not know any surviving
        // client's size. Resync the observers so one re-offers its
        // geometry and takes the lease over; without this the pane keeps
        // the departed client's size until an unrelated resize.
        resync_required.notify(model, .{ .origin = key, .workspace = lease.workspace });
    }
}

test "a workspace geometry lease is exclusive to one client generation" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.geometry_leases = @splat(null);

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const holder: ClientKey = .{ .id = 3, .generation = 4 };
    const stale_holder: ClientKey = .{ .id = 3, .generation = 3 };

    try std.testing.expect(acquire(model, holder, workspace));
    try std.testing.expect(acquire(model, holder, workspace));
    try std.testing.expect(!acquire(model, stale_holder, workspace));

    release(model, holder, workspace);

    try std.testing.expect(acquire(model, stale_holder, workspace));
}

test "workspace geometry leases remain bounded by workspace capacity" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.geometry_leases = @splat(null);

    const holder: ClientKey = .{ .id = 1, .generation = 1 };
    for (0..state_support.max_workspaces) |index| {
        const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(index + 1) };
        try std.testing.expect(acquire(model, holder, workspace));
    }

    const overflow: core.WorkspaceLocation = .{ .workspace = @enumFromInt(state_support.max_workspaces + 1) };
    try std.testing.expect(!acquire(model, holder, overflow));
}
