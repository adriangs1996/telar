//! Fixed-capacity ownership and generation-safe lookup of client sessions.

const core = @import("telar-core");
const Store = @import("Store.zig");
const std = @import("std");

pub const max_clients = core.ClientList.capacity;
/// Connections that may negotiate at once. Hooks of several agents connect
/// together; a connection that arrives with every slot taken is closed.
pub const max_pending_handshakes = 8;
/// A handshake still unfinished this long is interrupted at the next
/// maintenance tick, once a second, so a client that never finishes holds a
/// slot three seconds at most.
pub const handshake_deadline_ms: i64 = 2_000;

test "Store rejects exhausted identities before allocating a session" {
    var store: Store = .{ .next_id = std.math.maxInt(u64) };

    try std.testing.expectError(
        error.ClientIdentityExhausted,
        store.add(std.testing.allocator, .{ .stream = undefined }),
    );
    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "Store resolves only the retained client generation" {
    var store: Store = .{};
    const session = try store.add(std.testing.allocator, .{ .stream = undefined });
    defer {
        session.delivery.deinit(std.testing.allocator);
        std.testing.allocator.free(session.receive_buffer);
        std.testing.allocator.free(session.read_buffer);
        std.testing.allocator.destroy(session);
    }

    try std.testing.expect(store.resolve(session.key) == session);
    try std.testing.expect(store.resolve(.{
        .id = session.key.id,
        .generation = session.key.generation + 1,
    }) == null);
}

test "Store reports capacity from retained session count" {
    var store: Store = .{};
    store.count = store.items.len;

    try std.testing.expect(!store.hasCapacity());
    try std.testing.expectError(
        error.ClientLimitReached,
        store.add(std.testing.allocator, .{ .stream = undefined }),
    );
}
