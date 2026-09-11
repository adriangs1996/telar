//! Bounded registry for the proxy capabilities issued to pane generations.

const CredentialType = @import("Credential.zig");
const std = @import("std");
const identity = @import("identity.zig");
const pane_module = @import("telar-core").pane;
const Registry = @import("Registry.zig");
const max_agent_snapshot_entries_module = @import("telar-core").max_agent_snapshot_entries;

pub fn erase(slot: *?CredentialType, credential: *CredentialType) void {
    std.crypto.secureZero(u8, &credential.token);
    slot.* = null;
}

pub fn sameCredential(left: *const CredentialType, right: *const CredentialType) bool {
    if (left.pane_id != right.pane_id or left.pane_generation != right.pane_generation) {
        return false;
    }

    return std.crypto.timing_safe.eql([identity.token_bytes]u8, left.token, right.token);
}

fn testCredential(pane_id: u32, generation: u64, token: u8) !CredentialType {
    return .{
        .pane_id = try pane_module(pane_id),
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

    for (0..max_agent_snapshot_entries_module) |index| {
        const credential = try testCredential(7, index, @truncate(index));
        try registry.register(io, &credential);
    }

    const overflow = try testCredential(7, max_agent_snapshot_entries_module, 0xff);
    try std.testing.expectError(error.TooManyProxyCredentials, registry.register(io, &overflow));
}
