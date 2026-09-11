//! Bounded registry for the proxy capabilities issued to pane generations.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("identity.zig");

pub const Io = std.Io;
pub const schema = core.schema;

pub const capacity = schema.max_agent_snapshot_entries;

pub const PaneGeneration = @import("PaneGeneration.zig");

pub const Registry = @import("Registry.zig");

pub fn erase(slot: *?identity.Credential, credential: *identity.Credential) void {
    std.crypto.secureZero(u8, &credential.token);
    slot.* = null;
}

pub fn sameCredential(left: *const identity.Credential, right: *const identity.Credential) bool {
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

test "pane revocation removes every credential for only that generation" {
    const io = std.testing.io;
    var registry: Registry = .{};
    const current_a = try testCredential(7, 2, 0x5a);
    const current_b = try testCredential(7, 2, 0x6b);
    const next = try testCredential(7, 3, 0x7c);

    try registry.register(io, &current_a);
    try registry.register(io, &current_b);
    try registry.register(io, &next);

    registry.removePane(io, .{ .id = current_a.pane_id, .generation = current_a.pane_generation });

    try std.testing.expect(!registry.contains(io, &current_a));
    try std.testing.expect(!registry.contains(io, &current_b));
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
