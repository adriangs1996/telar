//! The machines one window holds. The
//! window's own client, in `Machines.local_slot`, is this machine's and owns
//! the configuration, the bars and the configuration watch. Every enabled
//! saved machine, and the one `--remote` names, gets a client of its own in
//! another slot that shares that configuration. The window presents one
//! machine; the others keep metadata only and never touch the host. A
//! change to `machines.json` reaches the window within a second.

const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");

const Machines = client.Machines;

/// The client identity one window slot presents on a machine, so the
/// runtime keeps one layout per window and machine.
pub fn machineIdentity(window_identity: core.ClientIdentity, destination: []const u8) core.ClientIdentity {
    const value = std.hash.Wyhash.hash(@intFromEnum(window_identity), destination);
    return @enumFromInt(if (value == 0) 1 else value);
}

pub const Retirement = enum { disabled, removed };

pub fn profileFor(profiles: *const core.MachineProfiles, id: core.MachineId) ?*const core.MachineProfile {
    for (profiles.slice()) |*profile| {
        if (profile.id == id) {
            return profile;
        }
    }

    return null;
}

// The temporary `--remote` row a new profile for the same destination
// takes over, so one destination never gets two clients.
pub fn temporaryFor(machines: *const Machines, destination: []const u8) ?u8 {
    for (machines.used, machines.id, 0..) |used, id, index| {
        const slot: u8 = @intCast(index);
        if (used and id == .invalid and slot != Machines.local_slot and std.mem.eql(u8, machines.destination(slot), destination)) {
            return slot;
        }
    }

    return null;
}

pub fn machineFor(machines: *const Machines, name: []const u8) ?u8 {
    for (machines.used, 0..) |used, index| {
        const slot: u8 = @intCast(index);
        if (!used or slot == Machines.local_slot) {
            continue;
        }

        if (std.mem.eql(u8, machines.destination(slot), name) or std.mem.eql(u8, machines.label(slot), name)) {
            return slot;
        }
    }

    return null;
}

pub fn dropHostEffects(app: *client.Client) void {
    const effects = &app.model.to_host;
    while (effects.pop()) |effect| {
        switch (effect) {
            .capture => |request| client.clipboard_capture.completeClipboardCapture(app, .{
                .execution_id = @enumFromInt(request.sequence),
                .result = error.NativeServiceUnavailable,
                // The failed capture is retired before its notification is published; a notification failure must not interrupt discarding the other host effects.
            }) catch {},
            else => {},
        }
    }

    effects.resume_input = false;
    effects.rebind_input = false;
    effects.pane_input = null;
    _ = effects.takePlacementInvalidation();
}
