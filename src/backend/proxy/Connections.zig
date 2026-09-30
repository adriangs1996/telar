//! The proxy's admitted connections, one row per connection slot. Each row
//! holds the phase its tunnel is in, when that phase began, when bytes last
//! moved and the sockets the tunnel owns, so the service can close a
//! connection that never authenticates, one that never reaches its origin,
//! and, when every slot is taken, the connection idle the longest.
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
/// A full table closes the connection idle the longest to admit a new one.
/// An HTTP/1.1 connection waiting for its next request is idle after a
/// minute.
pub const min_evictable_idle_ms: i64 = 60 * std.time.ms_per_s;
/// Any other connection may still wait on a response nobody streams, so it
/// counts as idle only after ten minutes without a byte, longer than a
/// model API keeps a request open.
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
    idle_eviction,
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

/// Shuts down the connection idle the longest, among those waiting for a
/// request for `min_evictable_idle_ms` and those silent for
/// `min_evictable_silence_ms`, and returns whether it found one. Its tunnel
/// ends and frees the row shortly after.
///
/// ```zig
/// if (connections.evictIdle(now_ms)) waitForRow();
/// ```
pub fn evictIdle(self: *Connections, now_ms: i64) bool {
    var victim: ?usize = null;
    var oldest_ms: i64 = std.math.maxInt(i64);

    for (0..capacity) |index| {
        if (!self.due(index, .idle_eviction, now_ms)) {
            continue;
        }

        const active_ms = self.active_ms[index].load(.monotonic);
        if (active_ms < oldest_ms) {
            oldest_ms = active_ms;
            victim = index;
        }
    }

    const index = victim orelse return false;
    return self.shutDown(index, .idle_eviction, now_ms);
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

    return switch (closure) {
        .connect_head_timeout => phase == .connect_head and now_ms - since_ms >= connect_head_timeout_ms,
        .establish_timeout => phase == .establishing and now_ms - since_ms >= establish_timeout_ms,
        .idle_eviction => switch (phase) {
            .idle => now_ms - active_ms >= min_evictable_idle_ms,
            .open => now_ms - active_ms >= min_evictable_silence_ms,
            .free, .connect_head, .establishing, .closing => false,
        },
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
    try std.testing.expectEqual(Expired{ .connect_head = 1 }, connections.expire(connect_head_timeout_ms));
    try std.testing.expect(readsEndOfStream(silent[0]));
    try std.testing.expectEqual(Phase.closing, connections.phase[@intFromEnum(head)].load(.acquire));

    try std.testing.expectEqual(Expired{ .establishing = 1 }, connections.expire(establish_timeout_ms));
    try std.testing.expect(readsEndOfStream(hung[0]));
    try std.testing.expect(readsEndOfStream(origin[0]));
    try std.testing.expectEqual(Expired{}, connections.expire(establish_timeout_ms * 2));
}

test "eviction closes the connection idle the longest, never a recently active one" {
    var connections: Connections = .{};
    const older = testSockets();
    defer closeSockets(older);
    const newer = testSockets();
    defer closeSockets(newer);

    const first = connections.acquire(older[0], 0).?;
    connections.enter(first, .idle, 0);
    const second = connections.acquire(newer[0], 0).?;
    connections.enter(second, .idle, 10);

    try std.testing.expect(!connections.evictIdle(min_evictable_idle_ms - 1));
    try std.testing.expect(connections.evictIdle(min_evictable_idle_ms + 10));
    try std.testing.expect(readsEndOfStream(older[0]));
    try std.testing.expect(!readsEndOfStream(newer[0]));
    try std.testing.expectEqual(Phase.idle, connections.phase[@intFromEnum(second)].load(.acquire));
}

test "a relaying connection is evicted only after its longer silence" {
    var connections: Connections = .{};
    const sockets = testSockets();
    defer closeSockets(sockets);

    const slot = connections.acquire(sockets[0], 0).?;
    connections.enter(slot, .open, 0);

    try std.testing.expect(!connections.evictIdle(min_evictable_silence_ms - 1));
    connections.touch(slot, min_evictable_silence_ms - 1);
    try std.testing.expect(!connections.evictIdle(min_evictable_silence_ms));
    try std.testing.expect(connections.evictIdle(2 * min_evictable_silence_ms - 1));
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
