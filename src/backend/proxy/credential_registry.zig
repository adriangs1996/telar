//! Bounded registry for the proxy capabilities issued to pane generations.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("identity.zig");

const Io = std.Io;
const schema = core.schema;

pub const capacity = schema.max_agent_snapshot_entries;

pub const PaneGeneration = struct {
    id: schema.PaneId,
    generation: u64,
};

pub const Registry = struct {
    mutex: Io.Mutex = .init,
    slots: [capacity]?identity.Credential = @splat(null),

    /// Copies one live capability into bounded registry storage. Exact
    /// duplicate credentials are rejected.
    ///
    /// ```zig
    /// try registry.register(io, &credential);
    /// ```
    pub fn register(registry: *Registry, io: Io, credential: *const identity.Credential) !void {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);

        var free: ?*?identity.Credential = null;

        for (&registry.slots) |*slot| {
            if (slot.*) |*existing| {
                if (sameCredential(existing, credential)) {
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
    pub fn remove(registry: *Registry, io: Io, credential: *const identity.Credential) void {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);

        for (&registry.slots) |*slot| {
            const existing = if (slot.*) |*value| value else continue;
            if (!sameCredential(existing, credential)) {
                continue;
            }

            erase(slot, existing);
            return;
        }
    }

    /// Revokes the capability owned by one exact pane generation while
    /// preserving credentials for reused pane IDs.
    ///
    /// ```zig
    /// registry.removePane(io, .{ .id = pane_id, .generation = generation });
    /// ```
    pub fn removePane(registry: *Registry, io: Io, pane: PaneGeneration) void {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);

        for (&registry.slots) |*slot| {
            const existing = if (slot.*) |*value| value else continue;
            if (existing.pane_id != pane.id or existing.pane_generation != pane.generation) {
                continue;
            }

            erase(slot, existing);
            return;
        }
    }

    /// Checks one complete capability using constant-time token comparison.
    ///
    /// ```zig
    /// if (!registry.contains(io, &credential)) {
    ///     rejectTunnel();
    /// }
    /// ```
    pub fn contains(registry: *Registry, io: Io, credential: *const identity.Credential) bool {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);

        for (&registry.slots) |*slot| {
            const existing = if (slot.*) |*value| value else continue;
            if (sameCredential(existing, credential)) {
                return true;
            }
        }

        return false;
    }
};

fn erase(slot: *?identity.Credential, credential: *identity.Credential) void {
    std.crypto.secureZero(u8, &credential.token);
    slot.* = null;
}

fn sameCredential(left: *const identity.Credential, right: *const identity.Credential) bool {
    if (left.pane_id != right.pane_id or left.pane_generation != right.pane_generation) {
        return false;
    }

    return std.crypto.timing_safe.eql([identity.token_bytes]u8, left.token, right.token);
}

fn testCredential(pane_id: u32, generation: u64, token: u8) !identity.Credential {
    return .{
        .pane_id = try schema.id.pane(pane_id),
        .pane_generation = generation,
        .token = .{token} ** identity.token_bytes,
    };
}

test "register, lookup, exact revocation, and duplicate rejection" {
    const io = std.testing.io;
    var registry: Registry = .{};
    const credential = try testCredential(7, 2, 0x5a);

    try registry.register(io, &credential);
    try std.testing.expect(registry.contains(io, &credential));
    try std.testing.expectError(error.DuplicateProxyCredential, registry.register(io, &credential));

    registry.remove(io, &credential);
    try std.testing.expect(!registry.contains(io, &credential));
}

test "pane revocation removes only that generation" {
    const io = std.testing.io;
    var registry: Registry = .{};
    const current = try testCredential(7, 2, 0x5a);
    const next = try testCredential(7, 3, 0x6b);

    try registry.register(io, &current);
    try registry.register(io, &next);

    registry.removePane(io, .{ .id = current.pane_id, .generation = current.pane_generation });

    try std.testing.expect(!registry.contains(io, &current));
    try std.testing.expect(registry.contains(io, &next));
}

test "pane identity and generation participate in credential identity" {
    const io = std.testing.io;
    var registry: Registry = .{};
    const registered = try testCredential(7, 2, 0x5a);
    const wrong_pane = try testCredential(8, 2, 0x5a);
    const wrong_generation = try testCredential(7, 3, 0x5a);
    const wrong_token = try testCredential(7, 2, 0x6b);

    try registry.register(io, &registered);

    try std.testing.expect(!registry.contains(io, &wrong_pane));
    try std.testing.expect(!registry.contains(io, &wrong_generation));
    try std.testing.expect(!registry.contains(io, &wrong_token));
}

test "registry rejects insertion beyond its fixed capacity" {
    const io = std.testing.io;
    var registry: Registry = .{};

    for (0..capacity) |index| {
        const credential = try testCredential(7, index, @truncate(index));
        try registry.register(io, &credential);
    }

    const overflow = try testCredential(7, capacity, 0xff);
    try std.testing.expectError(error.TooManyProxyCredentials, registry.register(io, &overflow));
}
