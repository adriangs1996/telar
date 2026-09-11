const store_support = @import("store_support.zig");
const SessionType = @import("Session.zig");
const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const ClientKey = @import("../../history/ClientKey.zig");
const RemovalResources = @import("RemovalResources.zig");
const Store = @This();

items: [store_support.max_clients]?*SessionType = @splat(null),
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
pub fn add(store: *Store, gpa: std.mem.Allocator, connection: SocketChannelType) !*SessionType {
    if (!store.hasCapacity()) {
        return error.ClientLimitReached;
    }

    if (store.next_id == 0 or store.next_id == std.math.maxInt(u64) or
        store.next_generation == 0 or store.next_generation == std.math.maxInt(u64))
    {
        return error.ClientIdentityExhausted;
    }

    const key: ClientKey = .{
        .id = store.next_id,
        .generation = store.next_generation,
    };

    for (&store.items) |*slot| {
        if (slot.* != null) {
            continue;
        }

        const session = try SessionType.create(gpa, key, connection);
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
pub fn resolve(store: *Store, key: ClientKey) ?*SessionType {
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
pub fn remove(store: *Store, resources: RemovalResources, key: ClientKey) bool {
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
pub fn deinit(store: *Store, io: std.Io, gpa: std.mem.Allocator) void {
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
