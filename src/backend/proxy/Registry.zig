const Registry = @This();
const source_namespace = @import("credential_registry.zig");
const identity = @import("identity.zig");
const PaneGeneration = @import("PaneGeneration.zig");
mutex: source_namespace.Io.Mutex = .init,
slots: [source_namespace.capacity]?identity.Credential = @splat(null),

/// Copies one live capability into bounded registry storage. Exact
/// duplicate credentials are rejected.
///
/// ```zig
/// try registry.register(io, &credential);
/// ```
pub fn register(registry: *Registry, io: source_namespace.Io, credential: *const identity.Credential) !void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    var free: ?*?identity.Credential = null;

    for (&registry.slots) |*slot| {
        if (slot.*) |*existing| {
            if (source_namespace.sameCredential(existing, credential)) {
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
pub fn remove(registry: *Registry, io: source_namespace.Io, credential: *const identity.Credential) void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (!source_namespace.sameCredential(existing, credential)) {
            continue;
        }

        source_namespace.erase(slot, existing);
        return;
    }
}

/// Revokes every capability owned by one exact pane generation while
/// preserving credentials for reused pane IDs.
///
/// ```zig
/// registry.removePane(io, .{ .id = pane_id, .generation = generation });
/// ```
pub fn removePane(registry: *Registry, io: source_namespace.Io, pane: PaneGeneration) void {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (existing.pane_id != pane.id or existing.pane_generation != pane.generation) {
            continue;
        }

        source_namespace.erase(slot, existing);
    }
}

/// Checks one complete capability using constant-time token comparison.
///
/// ```zig
/// if (!registry.contains(io, &credential)) {
///     rejectTunnel();
/// }
/// ```
pub fn contains(registry: *Registry, io: source_namespace.Io, credential: *const identity.Credential) bool {
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    for (&registry.slots) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (source_namespace.sameCredential(existing, credential)) {
            return true;
        }
    }

    return false;
}
