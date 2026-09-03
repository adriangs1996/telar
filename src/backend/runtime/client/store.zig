//! Fixed-capacity ownership and generation-safe lookup of client sessions.

const std = @import("std");
const core = @import("telar-core");
const session_mod = @import("session.zig");

const Io = std.Io;

pub const max_clients = 8;

pub const RemovalResources = struct {
    io: Io,
    gpa: std.mem.Allocator,
};

pub const Store = struct {
    items: [max_clients]?*session_mod.Session = @splat(null),
    count: usize = 0,
    next_id: u64 = 1,
    next_generation: u64 = 1,

    /// Reports whether another client session can be retained.
    ///
    /// ```zig
    /// if (!store.hasCapacity()) return error.ClientLimitReached;
    /// ```
    pub fn hasCapacity(store: *const Store) bool {
        return store.count < store.items.len;
    }

    /// Creates and retains a session under a fresh identity. The connection
    /// remains caller-owned when creation fails.
    ///
    /// ```zig
    /// const session = try store.add(gpa, connection);
    /// ```
    pub fn add(store: *Store, gpa: std.mem.Allocator, connection: core.transport.SocketChannel) !*session_mod.Session {
        if (!store.hasCapacity()) {
            return error.ClientLimitReached;
        }

        if (store.next_id == 0 or store.next_id == std.math.maxInt(u64) or
            store.next_generation == 0 or store.next_generation == std.math.maxInt(u64))
        {
            return error.ClientIdentityExhausted;
        }

        const key: session_mod.Key = .{
            .id = store.next_id,
            .generation = store.next_generation,
        };

        for (&store.items) |*slot| {
            if (slot.* != null) {
                continue;
            }

            const session = try session_mod.Session.create(gpa, key, connection);
            slot.* = session;
            store.next_id += 1;
            store.next_generation += 1;
            store.count += 1;
            return session;
        }
        unreachable;
    }

    /// Resolves only the exact retained client generation.
    ///
    /// ```zig
    /// const session = store.resolve(key) orelse return error.StaleClient;
    /// ```
    pub fn resolve(store: *Store, key: session_mod.Key) ?*session_mod.Session {
        for (&store.items) |*slot| {
            const session = slot.* orelse continue;
            if (session.key.id == key.id and session.key.generation == key.generation) {
                return session;
            }
        }
        return null;
    }

    /// Removes the exact session generation and releases all of its owned
    /// resources. A stale identity leaves the store unchanged.
    ///
    /// ```zig
    /// _ = store.remove(resources, key);
    /// ```
    pub fn remove(store: *Store, resources: RemovalResources, key: session_mod.Key) bool {
        for (&store.items) |*slot| {
            const session = slot.* orelse continue;
            if (session.key.id != key.id or session.key.generation != key.generation) {
                continue;
            }

            session.deinit(resources.io, resources.gpa);
            resources.gpa.destroy(session);
            slot.* = null;
            store.count -= 1;
            return true;
        }
        return false;
    }

    /// Shuts down and releases every retained session after its actors have
    /// relinquished their claims.
    ///
    /// ```zig
    /// store.deinit(io, gpa);
    /// ```
    pub fn deinit(store: *Store, io: Io, gpa: std.mem.Allocator) void {
        for (&store.items) |*slot| {
            if (slot.*) |session| {
                session.connection.shutdown(io);
                std.debug.assert(!session.read_pending and !session.send_pending);
                session.deinit(io, gpa);
                gpa.destroy(session);
            }
            slot.* = null;
        }
        store.count = 0;
    }
};

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
