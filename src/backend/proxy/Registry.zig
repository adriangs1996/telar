const std = @import("std");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const CredentialType = @import("Credential.zig");
const credential_registry = @import("credential_registry.zig");
const PaneGeneration = @import("PaneGeneration.zig");
const Registry = @This();

mutex: std.Io.Mutex = .init,
slots: [max_agent_snapshot_entries]?CredentialType = @splat(null),

/// Copies one live capability into bounded registry storage. Exact
/// duplicate credentials are rejected.
///
/// ```zig
/// try registry.register(io, &credential);
/// ```
pub fn register(registry: *Registry, io: std.Io, credential: *const CredentialType) !void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    var free: ?*?CredentialType = null;

    for (&registry.slots) |*slot| {
        if (slot.*) |*existing| {
            if (credential_registry.sameCredential(existing, credential)) {
                return error.DuplicateProxyCredential;
            }
        } else if (free == null) {
            free = slot;
        }
    }

    const destination = free orelse return error.TooManyProxyCredentials;
    destination.* = credential.*;
}

/// Revokes one exact credential and scrubs its stored token.
///
/// ```zig
/// registry.remove(io, &credential);
/// ```
pub fn remove(registry: *Registry, io: std.Io, credential: *const CredentialType) void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
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
pub fn removePane(registry: *Registry, io: std.Io, pane: PaneGeneration) void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (existing.pane_id != pane.id or existing.pane_generation != pane.generation) {
            continue;
        }

        credential_registry.erase(slot, existing);
    }
}

/// Checks one complete capability using constant-time token comparison.
///
/// ```zig
/// if (!registry.contains(io, &credential)) {
///     rejectTunnel();
/// }
/// ```
pub fn contains(registry: *Registry, io: std.Io, credential: *const CredentialType) bool {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (credential_registry.sameCredential(existing, credential)) {
            return true;
        }
    }

    return false;
}
