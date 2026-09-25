const core = @import("telar-core");
const std = @import("std");
const Credential = @import("Credential.zig");
const CredentialId = @import("CredentialId.zig");
const credential_registry = @import("credential_registry.zig");
const Registry = @This();

mutex: std.Io.Mutex = .init,
slots: [core.max_agent_snapshot_entries]?Credential = @splat(null),
/// The registration serial of each slot's credential.
serials: [core.max_agent_snapshot_entries]u64 = @splat(0),
/// Serials are never reused, so a revoked credential's id stays dead even
/// after its slot holds another credential.
next_serial: u64 = 1,

/// Copies one live capability into bounded registry storage. Exact
/// duplicate credentials are rejected.
///
/// ```zig
/// try registry.register(io, &credential);
/// ```
pub fn register(self: *Registry, io: std.Io, credential: *const Credential) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    var free: ?usize = null;

    for (&self.slots, 0..) |*slot, index| {
        if (slot.*) |*existing| {
            if (credential_registry.sameCredential(existing, credential)) {
                return error.DuplicateProxyCredential;
            }
        } else if (free == null) {
            free = index;
        }
    }

    const destination = free orelse return error.TooManyProxyCredentials;
    self.slots[destination] = credential.*;
    self.serials[destination] = self.next_serial;
    self.next_serial += 1;
}

/// Revokes one exact credential and scrubs its stored token.
///
/// ```zig
/// registry.remove(io, &credential);
/// ```
pub fn remove(self: *Registry, io: std.Io, credential: *const Credential) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (&self.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (!credential_registry.sameCredential(existing, credential)) {
            continue;
        }

        credential_registry.erase(slot, existing);
        return;
    }
}

/// Revokes every capability owned by one exact pane generation while
/// preserving credentials for reused pane IDs.
///
/// ```zig
/// registry.removePane(io, .{ .id = pane_id, .generation = generation });
/// ```
pub fn removePane(self: *Registry, io: std.Io, pane: PaneGeneration) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (&self.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (existing.pane_id != pane.id or existing.pane_generation != pane.generation) {
            continue;
        }

        credential_registry.erase(slot, existing);
    }
}

/// Authenticates one complete capability using constant-time token
/// comparison and returns its non-secret identity while it is live.
///
/// ```zig
/// const owner = registry.identify(io, &credential) orelse return rejectTunnel();
/// ```
pub fn identify(self: *Registry, io: std.Io, credential: *const Credential) ?CredentialId {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (&self.slots, self.serials) |*slot, serial| {
        const existing = if (slot.*) |*value| value else continue;
        if (credential_registry.sameCredential(existing, credential)) {
            return .{
                .pane_id = existing.pane_id,
                .pane_generation = existing.pane_generation,
                .serial = serial,
            };
        }
    }

    return null;
}

/// Reports whether the credential behind an identity is still registered.
///
/// ```zig
/// if (!registry.holds(io, event.owner)) {
///     continue;
/// }
/// ```
pub fn holds(self: *Registry, io: std.Io, owner: CredentialId) bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (&self.slots, self.serials) |*slot, serial| {
        const existing = if (slot.*) |*value| value else continue;
        if (serial == owner.serial) {
            std.debug.assert(existing.pane_id == owner.pane_id and existing.pane_generation == owner.pane_generation);
            return true;
        }
    }

    return false;
}

const PaneGeneration = struct {
    id: core.PaneId,
    generation: u64,
};
