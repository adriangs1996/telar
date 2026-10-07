//! One client generation holds the geometry lease of a workspace: only it
//! may resize the workspace's PTYs. Spectators crop or letterbox instead.
//! The lease is a column of the workspace table, so a proposed workspace
//! can hold it before its first pane launch commits.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const ClientKey = @import("../history/ClientKey.zig");
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
