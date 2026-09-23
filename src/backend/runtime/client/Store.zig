const core = @import("telar-core");
const store_support = @import("store_support.zig");
const SessionType = @import("Session.zig");
const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const RemovalResources = @import("RemovalResources.zig");
const Store = @This();

comptime {
    std.debug.assert(store_support.max_clients <= @bitSizeOf(u8));
}

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
pub fn add(store: *Store, gpa: std.mem.Allocator, connection: core.SocketChannel) !*SessionType {
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

    for (&store.items, 0..) |*slot, index| {
        if (slot.* != null) {
            continue;
        }

        const session = try SessionType.create(gpa, key, connection);
        session.attachments.observer = @as(u8, 1) << @intCast(index);
        slot.* = session;
        store.next_id += 1;
        store.next_generation += 1;
        store.count += 1;
        return session;
    }
    unreachable;
}

/// Pops the lowest client of an observer mask and returns its session.
///
/// ```zig
/// var observers = pane.observers;
/// while (store.nextObserver(&observers)) |session| { ... }
/// ```
pub fn nextObserver(store: *Store, observers: *u8) ?*SessionType {
    while (observers.* != 0) {
        const index = @ctz(observers.*);
        observers.* &= observers.* - 1;
        if (store.items[index]) |session| {
            return session;
        }
    }

    return null;
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
