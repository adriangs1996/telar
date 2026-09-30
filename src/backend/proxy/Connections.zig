//! The proxy's admitted connections, one row per connection slot. Each row
//! holds the phase its tunnel is in, when that phase began, when bytes last
//! moved, how many exchanges are in flight and the sockets the tunnel owns,
//! so the service can close a connection that never authenticates, one that
//! never reaches its origin, and, when it must make room, the connection
//! that costs the least to lose.
//!
//! Tunnels write their own row with atomics. The service only shuts a
//! socket down, which wakes the tunnel's blocked read; the tunnel still
//! closes it. A row's guard is held around every shutdown and around the
//! moment the tunnel gives a socket up, so a shutdown never reaches a
//! descriptor another connection reused.
const core = @import("telar-core");
const std = @import("std");
const SlotSnapshot = @import("SlotSnapshot.zig");
const Connections = @This();

pub const Handle = std.Io.net.Socket.Handle;

/// Connections admitted at once across every pane of the runtime. One agent
/// keeps several keep-alive sockets per host (its API, telemetry, MCP
/// servers, package registries), and several panes of agents and builds
/// share the bound.
pub const capacity: u32 = 256;
/// A connection must send its whole CONNECT head within this long.
pub const connect_head_timeout_ms: i64 = 10 * std.time.ms_per_s;
/// A connection must reach its origin and finish TLS within this long.
pub const establish_timeout_ms: i64 = 30 * std.time.ms_per_s;
pub const connect_head_timeout_limit = core.Limit.declare("proxy.connect_head_timeout_ms", "ms", connect_head_timeout_ms);
pub const establish_timeout_limit = core.Limit.declare("proxy.establish_timeout_ms", "ms", establish_timeout_ms);
/// Connections still sending their CONNECT head at once. A local process
/// that opens silent connections fills at most these rows, so it can never
/// lock authenticated clients out of the rest.
pub const max_unauthenticated: u32 = 64;
pub const unauthenticated_limit = core.Limit.declare("proxy.max_unauthenticated", "connections", max_unauthenticated);
/// To make room, the proxy first closes the oldest connection still sending
/// its CONNECT head after a second, far longer than a client needs.
pub const min_evictable_connect_head_ms: i64 = std.time.ms_per_s;
/// Then an HTTP/1.1 connection that has waited a minute for its next
/// request.
pub const min_evictable_idle_ms: i64 = 60 * std.time.ms_per_s;
/// Last, a connection with no exchange in flight and no byte for ten
/// minutes. A connection with an exchange in flight is never closed to make
/// room, however long its response takes.
pub const min_evictable_silence_ms: i64 = 10 * std.time.ms_per_min;

/// What a row's tunnel is doing.
pub const Phase = enum(u8) {
    free,
    /// Reading the CONNECT head, before authentication.
    connect_head,
    /// Connecting to the origin and establishing TLS.
    establishing,
    /// Relaying traffic.
    open,
    /// Between HTTP/1.1 exchanges, waiting for the next request.
    idle,
    /// Giving its sockets up; never shut down again.
    closing,
};

/// Why the service closes a connection.
const Closure = enum {
    connect_head_timeout,
    establish_timeout,
    /// Making room: a connection still sending its CONNECT head.
    evict_unauthenticated,
    /// Making room: an HTTP/1.1 connection between exchanges.
    evict_idle,
    /// Making room: a connection with nothing in flight and no traffic.
    evict_silent,
};

/// Which connections making room may close.
pub const Eviction = enum {
    /// Only one still sending its CONNECT head.
    unauthenticated,
    /// Any evictable one, cheapest first.
    any,
};

/// One admitted connection's row.
pub const Slot = enum(u32) { _ };

phase: [capacity]std.atomic.Value(Phase) = @splat(.init(.free)),
/// When the current phase began, on the awake clock.
since_ms: [capacity]std.atomic.Value(i64) = @splat(.init(0)),
/// When bytes last moved, on the awake clock.
active_ms: [capacity]std.atomic.Value(i64) = @splat(.init(0)),
child: [capacity]Handle = undefined,
origin: [capacity]?Handle = @splat(null),
/// Exchanges in flight: an HTTP/1.1 request and its response, or HTTP/2
/// streams. A row with any is never evicted.
in_flight: [capacity]std.atomic.Value(u32) = @splat(.init(0)),
guard: [capacity]std.atomic.Mutex = @splat(.unlocked),
active: std.atomic.Value(u32) = .init(0),
limit_drops: std.atomic.Value(u64) = .init(0),

/// Admits one accepted socket into a free row, or returns null when every
/// row is taken. Only the accept loop calls it.
///
/// ```zig
/// const slot = connections.acquire(stream.socket.handle, now_ms) orelse return connections.refuse();
/// ```
pub fn acquire(self: *Connections, child: Handle, now_ms: i64) ?Slot {
    for (&self.phase, 0..) |*phase, index| {
        if (phase.load(.acquire) != .free) {
            continue;
        }

        self.child[index] = child;
        self.origin[index] = null;
        self.in_flight[index].store(0, .monotonic);
        self.since_ms[index].store(now_ms, .monotonic);
        self.active_ms[index].store(now_ms, .monotonic);
        phase.store(.connect_head, .release);
        _ = self.active.fetchAdd(1, .monotonic);
        return @enumFromInt(index);
    }

    return null;
}

/// Counts one connection refused at the bound.
///
/// ```zig
/// connections.refuse();
/// ```
pub fn refuse(self: *Connections) void {
    _ = self.limit_drops.fetchAdd(1, .monotonic);
}

/// Moves a connection to its next phase.
///
/// ```zig
/// connections.enter(slot, .establishing, now_ms);
/// ```
pub fn enter(self: *Connections, slot: Slot, phase: Phase, now_ms: i64) void {
    const index = @intFromEnum(slot);
    self.since_ms[index].store(now_ms, .monotonic);
    self.active_ms[index].store(now_ms, .monotonic);
    self.phase[index].store(phase, .release);
}

/// Records that bytes moved on a connection.
///
/// ```zig
/// connections.touch(slot, now_ms);
/// ```
pub fn touch(self: *Connections, slot: Slot, now_ms: i64) void {
    self.active_ms[@intFromEnum(slot)].store(now_ms, .monotonic);
}

/// Records one exchange starting, which keeps the connection from being
/// closed to make room until it ends.
///
/// ```zig
/// connections.beginExchange(slot);
/// ```
pub fn beginExchange(self: *Connections, slot: Slot) void {
    _ = self.in_flight[@intFromEnum(slot)].fetchAdd(1, .monotonic);
}

/// Records one exchange ending; an end without a start is ignored.
///
/// ```zig
/// connections.endExchange(slot);
/// ```
pub fn endExchange(self: *Connections, slot: Slot) void {
    const counter = &self.in_flight[@intFromEnum(slot)];
    var current = counter.load(.monotonic);
    while (current != 0) {
        current = counter.cmpxchgWeak(current, current - 1, .monotonic, .monotonic) orelse return;
    }
}

/// Counts the connections still sending their CONNECT head.
///
/// ```zig
/// if (connections.unauthenticated() >= max_unauthenticated) makeRoom();
/// ```
pub fn unauthenticated(self: *const Connections) u32 {
    var count: u32 = 0;
    for (&self.phase) |*phase| {
        count += @intFromBool(phase.load(.acquire) == .connect_head);
    }

    return count;
}

/// Records the origin socket, so a deadline can wake a read on it too.
///
/// ```zig
/// connections.attachOrigin(slot, upstream.socket.handle);
/// defer connections.detachOrigin(slot);
/// ```
pub fn attachOrigin(self: *Connections, slot: Slot, origin: Handle) void {
    const index = @intFromEnum(slot);
    self.lock(index);
    defer self.guard[index].unlock();

    self.origin[index] = origin;
}

/// Forgets the origin socket before the tunnel closes it.
///
/// ```zig
/// connections.detachOrigin(slot);
/// upstream.close(io);
/// ```
pub fn detachOrigin(self: *Connections, slot: Slot) void {
    const index = @intFromEnum(slot);
    self.lock(index);
    defer self.guard[index].unlock();

    self.origin[index] = null;
}

/// Stops every shutdown of the row before the tunnel closes its child
/// socket; `release` then frees the row.
///
/// ```zig
/// connections.retire(slot);
/// stream.close(io);
/// connections.release(slot);
/// ```
pub fn retire(self: *Connections, slot: Slot) void {
    const index = @intFromEnum(slot);
    self.lock(index);
    defer self.guard[index].unlock();

    self.origin[index] = null;
    self.phase[index].store(.closing, .release);
}

/// Frees a retired row for the next connection.
///
/// ```zig
/// connections.release(slot);
/// ```
pub fn release(self: *Connections, slot: Slot) void {
    const index = @intFromEnum(slot);
    std.debug.assert(self.phase[index].load(.acquire) == .closing);
    self.phase[index].store(.free, .release);
    const previous = self.active.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
}

/// Shuts down every connection past its phase deadline and returns how
/// many it closed for each reason.
///
/// ```zig
/// const closed = connections.expire(now_ms);
/// ```
pub fn expire(self: *Connections, now_ms: i64) Expired {
    var expired: Expired = .{};

    for (0..capacity) |index| {
        switch (self.phase[index].load(.acquire)) {
            .connect_head => if (self.shutDown(index, .connect_head_timeout, now_ms)) {
                expired.connect_head += 1;
            },
            .establishing => if (self.shutDown(index, .establish_timeout, now_ms)) {
                expired.establishing += 1;
            },
            .free, .open, .idle, .closing => {},
        }
    }

    return expired;
}

/// Shuts down one connection to make room and returns whether it found
/// one. It looks in order of what losing a connection costs: the oldest
/// still sending its CONNECT head after `min_evictable_connect_head_ms`,
/// then the HTTP/1.1 connection waiting longest past
/// `min_evictable_idle_ms`, then the connection silent longest past
/// `min_evictable_silence_ms`; never one with an exchange in flight.
/// `.unauthenticated` stops after the first. The closed connection's
/// tunnel ends and frees its row shortly after.
///
/// ```zig
/// if (connections.evict(now_ms, .any)) waitForRow();
/// ```
pub fn evict(self: *Connections, now_ms: i64, scope: Eviction) bool {
    const order = [_]Closure{ .evict_unauthenticated, .evict_idle, .evict_silent };
    const classes: []const Closure = switch (scope) {
        .unauthenticated => order[0..1],
        .any => &order,
    };

    for (classes) |closure| {
        const index = self.oldest(closure, now_ms) orelse continue;
        if (self.shutDown(index, closure, now_ms)) {
            return true;
        }
    }

    return false;
}

/// The row `closure` applies to that has waited the longest.
fn oldest(self: *const Connections, closure: Closure, now_ms: i64) ?usize {
    var found: ?usize = null;
    var oldest_ms: i64 = std.math.maxInt(i64);

    for (0..capacity) |index| {
        if (!self.due(index, closure, now_ms)) {
            continue;
        }

        const waited_from = switch (closure) {
            .evict_unauthenticated => self.since_ms[index].load(.monotonic),
            else => self.active_ms[index].load(.monotonic),
        };
        if (waited_from < oldest_ms) {
            oldest_ms = waited_from;
            found = index;
        }
    }

    return found;
}

/// Returns a lock-free metrics snapshot.
///
/// ```zig
/// const metrics = connections.snapshot();
/// ```
pub fn snapshot(self: *const Connections) SlotSnapshot {
    return .{
        .active = self.active.load(.monotonic),
        .limit_drops = self.limit_drops.load(.monotonic),
    };
}

/// Shuts both sockets of a row down when the closure is still due once the
/// row is locked: the row may have ended, or been admitted again, since the
/// caller looked at it.
fn shutDown(self: *Connections, index: usize, closure: Closure, now_ms: i64) bool {
    self.lock(index);
    defer self.guard[index].unlock();

    if (!self.due(index, closure, now_ms)) {
        return false;
    }

    _ = std.c.shutdown(self.child[index], std.c.SHUT.RDWR);
    if (self.origin[index]) |origin| {
        _ = std.c.shutdown(origin, std.c.SHUT.RDWR);
    }

    self.phase[index].store(.closing, .release);
    return true;
}

/// Whether a row's phase and clocks call for `closure` at `now_ms`.
fn due(self: *const Connections, index: usize, closure: Closure, now_ms: i64) bool {
    const phase = self.phase[index].load(.acquire);
    const since_ms = self.since_ms[index].load(.monotonic);
    const active_ms = self.active_ms[index].load(.monotonic);

    const quiet = self.in_flight[index].load(.monotonic) == 0;

    return switch (closure) {
        .connect_head_timeout => phase == .connect_head and now_ms - since_ms >= connect_head_timeout_ms,
        .establish_timeout => phase == .establishing and now_ms - since_ms >= establish_timeout_ms,
        .evict_unauthenticated => phase == .connect_head and now_ms - since_ms >= min_evictable_connect_head_ms,
        .evict_idle => phase == .idle and quiet and now_ms - active_ms >= min_evictable_idle_ms,
        .evict_silent => phase == .open and quiet and now_ms - active_ms >= min_evictable_silence_ms,
    };
}

fn lock(self: *Connections, index: usize) void {
    while (!self.guard[index].tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// Connections `expire` closed, by the phase whose deadline passed.
const Expired = struct {
    connect_head: u32 = 0,
    establishing: u32 = 0,
};

fn testSockets() [2]Handle {
    var sockets: [2]std.c.fd_t = undefined;
    std.debug.assert(std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) == 0);
    return sockets;
}

fn closeSockets(sockets: [2]Handle) void {
    _ = std.c.close(sockets[0]);
    _ = std.c.close(sockets[1]);
}

fn readsEndOfStream(handle: Handle) bool {
    var byte: [1]u8 = undefined;
    return std.c.recv(handle, &byte, byte.len, std.c.MSG.DONTWAIT) == 0;
}

test "a full table counts a drop and a released row admits again" {
    var connections: Connections = .{};
    const full: SlotSnapshot = .{
        .active = capacity,
        .limit_drops = 1,
    };

    for (0..capacity) |_| {
        try std.testing.expect(connections.acquire(0, 0) != null);
    }

    try std.testing.expect(connections.acquire(0, 0) == null);
    connections.refuse();
    try std.testing.expectEqual(full, connections.snapshot());

    const slot: Slot = @enumFromInt(7);
    connections.retire(slot);
    connections.release(slot);
    try std.testing.expectEqual(slot, connections.acquire(0, 0).?);
    try std.testing.expectEqual(full, connections.snapshot());
}

test "a connection past its CONNECT head or establishment deadline is shut down" {
    var connections: Connections = .{};
    const silent = testSockets();
    defer closeSockets(silent);
    const hung = testSockets();
    defer closeSockets(hung);
    const origin = testSockets();
    defer closeSockets(origin);

    const head = connections.acquire(silent[0], 0).?;
    const establishing = connections.acquire(hung[0], 0).?;
    connections.enter(establishing, .establishing, 0);
    connections.attachOrigin(establishing, origin[0]);

    try std.testing.expectEqual(Expired{}, connections.expire(connect_head_timeout_ms - 1));
    const closed_connect_head: Expired = .{
        .connect_head = 1,
    };
    try std.testing.expectEqual(closed_connect_head, connections.expire(connect_head_timeout_ms));
    try std.testing.expect(readsEndOfStream(silent[0]));
    try std.testing.expectEqual(Phase.closing, connections.phase[@intFromEnum(head)].load(.acquire));

    const closed_establishing: Expired = .{
        .establishing = 1,
    };
    try std.testing.expectEqual(closed_establishing, connections.expire(establish_timeout_ms));
    try std.testing.expect(readsEndOfStream(hung[0]));
    try std.testing.expect(readsEndOfStream(origin[0]));
    try std.testing.expectEqual(Expired{}, connections.expire(establish_timeout_ms * 2));
}

test "making room closes a waiting HTTP/1.1 connection before a silent one, and never one in flight" {
    var connections: Connections = .{};
    const waiting = testSockets();
    defer closeSockets(waiting);
    const silent = testSockets();
    defer closeSockets(silent);
    const thinking = testSockets();
    defer closeSockets(thinking);

    const silent_slot = connections.acquire(silent[0], 0).?;
    connections.enter(silent_slot, .open, 0);
    const thinking_slot = connections.acquire(thinking[0], 0).?;
    connections.enter(thinking_slot, .open, 0);
    connections.beginExchange(thinking_slot);
    const now_ms = 2 * min_evictable_silence_ms;
    const waiting_slot = connections.acquire(waiting[0], 0).?;
    connections.enter(waiting_slot, .idle, now_ms - min_evictable_idle_ms);

    try std.testing.expect(connections.evict(now_ms, .any));
    try std.testing.expect(readsEndOfStream(waiting[0]));
    try std.testing.expect(!readsEndOfStream(silent[0]));

    try std.testing.expect(connections.evict(now_ms, .any));
    try std.testing.expect(readsEndOfStream(silent[0]));

    try std.testing.expect(!connections.evict(now_ms, .any));
    try std.testing.expect(!readsEndOfStream(thinking[0]));

    connections.endExchange(thinking_slot);
    connections.endExchange(thinking_slot);
    try std.testing.expect(connections.evict(now_ms, .any));
    try std.testing.expect(readsEndOfStream(thinking[0]));
}

test "a connection still sending its CONNECT head goes first, once it had a second" {
    var connections: Connections = .{};
    const idle = testSockets();
    defer closeSockets(idle);
    const unauthenticated_socket = testSockets();
    defer closeSockets(unauthenticated_socket);

    const idle_slot = connections.acquire(idle[0], 0).?;
    connections.enter(idle_slot, .idle, 0);
    const now_ms = 2 * min_evictable_idle_ms;
    _ = connections.acquire(unauthenticated_socket[0], now_ms - min_evictable_connect_head_ms + 1).?;
    try std.testing.expectEqual(@as(u32, 1), connections.unauthenticated());

    try std.testing.expect(!connections.evict(now_ms, .unauthenticated));
    try std.testing.expect(connections.evict(now_ms + 1, .any));
    try std.testing.expect(readsEndOfStream(unauthenticated_socket[0]));
    try std.testing.expect(!readsEndOfStream(idle[0]));
    try std.testing.expectEqual(@as(u32, 0), connections.unauthenticated());
}

test "a relaying connection is evicted only after its longer silence" {
    var connections: Connections = .{};
    const sockets = testSockets();
    defer closeSockets(sockets);

    const slot = connections.acquire(sockets[0], 0).?;
    connections.enter(slot, .open, 0);

    try std.testing.expect(!connections.evict(min_evictable_silence_ms - 1, .any));
    connections.touch(slot, min_evictable_silence_ms - 1);
    try std.testing.expect(!connections.evict(min_evictable_silence_ms, .any));
    try std.testing.expect(connections.evict(2 * min_evictable_silence_ms - 1, .any));
    try std.testing.expect(readsEndOfStream(sockets[0]));
}

test "a retired row is never shut down" {
    var connections: Connections = .{};
    const sockets = testSockets();
    defer closeSockets(sockets);

    const slot = connections.acquire(sockets[0], 0).?;
    connections.retire(slot);

    try std.testing.expectEqual(Expired{}, connections.expire(connect_head_timeout_ms));
    try std.testing.expect(!readsEndOfStream(sockets[0]));
    connections.release(slot);
}
