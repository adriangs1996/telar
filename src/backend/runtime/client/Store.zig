const localsocket = @import("localsocket");
const store_support = @import("store_support.zig");
const Session = @import("Session.zig");
const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const Store = @This();

comptime {
    std.debug.assert(store_support.max_clients <= @bitSizeOf(u8));
}

items: [store_support.max_clients]?*Session = @splat(null),
count: usize = 0,
next_id: u64 = 1,
next_generation: u64 = 1,

/// Reports whether another client session can be retained.
///
/// ```zig
/// if (!store.hasCapacity()) return error.ClientLimitReached;
/// ```
pub fn hasCapacity(self: *const Store) bool {
    return self.count < self.items.len;
}

/// Whether one more client fits after `reserved` others, such as
/// connections still negotiating, have joined.
///
/// ```zig
/// if (!store.hasCapacityAfter(handshakes.count())) return;
/// ```
pub fn hasCapacityAfter(self: *const Store, reserved: usize) bool {
    return self.count + reserved < self.items.len;
}

/// Creates and retains a session under a fresh identity. The connection
/// remains caller-owned when creation fails.
///
/// ```zig
/// const session = try store.add(gpa, connection);
/// ```
pub fn add(self: *Store, gpa: std.mem.Allocator, connection: localsocket.SocketChannel) !*Session {
    if (!self.hasCapacity()) {
        return error.ClientLimitReached;
    }

    if (self.next_id == 0 or self.next_id == std.math.maxInt(u64) or
        self.next_generation == 0 or self.next_generation == std.math.maxInt(u64))
    {
        return error.ClientIdentityExhausted;
    }

    const key: ClientKey = .{
        .id = self.next_id,
        .generation = self.next_generation,
    };

    for (&self.items, 0..) |*slot, index| {
        if (slot.* != null) {
            continue;
        }

        const session = try Session.create(gpa, key, connection);
        session.slot = index;
        slot.* = session;
        self.next_id += 1;
        self.next_generation += 1;
        self.count += 1;
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
pub fn nextObserver(self: *Store, observers: *u8) ?*Session {
    while (observers.* != 0) {
        const index = @ctz(observers.*);
        observers.* &= observers.* - 1;
        if (self.items[index]) |session| {
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
pub fn resolve(self: *Store, key: ClientKey) ?*Session {
    for (&self.items) |*slot| {
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
pub fn remove(self: *Store, resources: RemovalResources, key: ClientKey) bool {
    for (&self.items) |*slot| {
        const session = slot.* orelse continue;
        if (session.key.id != key.id or session.key.generation != key.generation) {
            continue;
        }

        session.deinit(resources.io, resources.gpa);
        resources.gpa.destroy(session);
        slot.* = null;
        self.count -= 1;
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
pub fn deinit(self: *Store, io: std.Io, gpa: std.mem.Allocator) void {
    for (&self.items) |*slot| {
        if (slot.*) |session| {
            session.connection.shutdown(io);
            std.debug.assert(!session.read_pending and !session.send_pending);
            session.deinit(io, gpa);
            gpa.destroy(session);
        }
        slot.* = null;
    }
    self.count = 0;
}

const RemovalResources = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
};
