//! Name resolutions in flight, one row per host name. A row holds the name,
//! how many tunnels wait for its answer, and the addresses or the failure
//! its worker thread leaves there.
//!
//! The system resolver cannot be interrupted: on macOS `getaddrinfo` returns
//! only when the resolver gives up. A resolution therefore outlives the
//! tunnel that asked for it, and the proxy service itself, so the table that
//! proxies use is static (`service_support.resolutions`): its rows are never
//! freed, and a worker that returns after its proxy stopped still finds its
//! row. The bound is the process's for the same reason. A thread blocked in
//! the resolver belongs to no service, so `capacity` holds across every
//! service the process starts.
//!
//! `guard` protects `waiters` and every change of `phase`. A worker writes
//! `addresses`, `found` and `failure` only while its row is `resolving`;
//! waiters read them only once it is `resolved`, and a row with waiters is
//! never removed.
const core = @import("telar-core");
const std = @import("std");
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;
const Resolutions = @This();

/// Host names resolving at once. Tunnels that ask for the same name share
/// one row, so this bounds distinct names, and with them the threads and
/// descriptors the system resolver holds while it does not answer.
pub const capacity: u32 = 64;
pub const capacity_limit = core.Limit.declare("proxy.max_resolutions", "host names", capacity);
/// Addresses kept per name; a tunnel tries them in the resolver's order.
pub const max_addresses = 32;
pub const addresses_limit = core.Limit.declare("proxy.max_resolved_addresses", "addresses", max_addresses);

/// What a row's resolution is doing. Waiters sleep on it as a futex word.
pub const Phase = enum(u32) {
    free,
    /// Its worker is inside the resolver.
    resolving,
    /// Its worker left an answer and at least one tunnel has yet to read it.
    resolved,
};

/// Why a name has no addresses.
pub const Failure = error{
    UnknownHostName,
    NameServerFailure,
    AddressFamilyUnsupported,
    SystemResources,
    Unexpected,
};

/// Resolves `host` into `addresses`, each with port 0, and returns how many
/// addresses the name has; the ones past `addresses.len` are not written.
/// It runs on a worker thread and may block for as long as the system
/// resolver does.
pub const Resolver = *const fn (host: HostName, addresses: []IpAddress) Failure!usize;

/// One name's row.
pub const Slot = enum(u32) { _ };

/// What every worker of this table calls.
resolver: Resolver,
phase: [capacity]std.atomic.Value(Phase) = @splat(.init(.free)),
// SAFETY: add copies the hostname before publishing a resolving row; find and the worker read only host_len bytes.
host: [capacity][HostName.max_len]u8 = undefined,
// SAFETY: add sets the hostname length before publishing a resolving row; free rows are skipped.
host_len: [capacity]u8 = undefined,
/// The Io its tunnels wait through; the worker wakes them with it.
// SAFETY: add assigns Io before publishing a resolving row; free rows are skipped.
io: [capacity]std.Io = undefined,
/// Tunnels waiting for the answer or reading it.
waiters: [capacity]u32 = @splat(0),
// SAFETY: The resolver fills at most max_addresses entries; readers wait for resolution success and cap found to that capacity.
addresses: [capacity][max_addresses]IpAddress = undefined,
/// Addresses the name has, which may exceed `max_addresses`.
// SAFETY: Resolution completion sets found on success; readers wait for resolved and check failure before using it.
found: [capacity]usize = undefined,
// SAFETY: Resolution completion sets failure on both outcomes before publishing resolved; readers wait for that phase.
failure: [capacity]?Failure = undefined,
guard: std.atomic.Mutex = .unlocked,

/// Takes the guard every other method and every change of `phase` or
/// `waiters` needs. It spins: the guard is held for a scan of the names or
/// one wake, never across the resolver.
///
/// ```zig
/// resolutions.lock();
/// defer resolutions.unlock();
/// ```
pub fn lock(self: *Resolutions) void {
    while (!self.guard.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// Gives the guard back.
///
/// ```zig
/// resolutions.unlock();
/// ```
pub fn unlock(self: *Resolutions) void {
    self.guard.unlock();
}

/// The row resolving or holding `host` for tunnels that wait through `io`.
/// Names compare without case, as DNS does. The caller holds the guard.
///
/// ```zig
/// const slot = resolutions.find(host, io) orelse resolutions.add(host, io);
/// ```
pub fn find(self: *const Resolutions, host: HostName, io: std.Io) ?Slot {
    for (&self.phase, 0..) |*phase, index| {
        if (phase.load(.monotonic) == .free) {
            continue;
        }

        const name = self.host[index][0..self.host_len[index]];
        if (std.ascii.eqlIgnoreCase(name, host.bytes) and sameIo(self.io[index], io)) {
            return @enumFromInt(index);
        }
    }

    return null;
}

/// Adds a row for `host` in `resolving`, with no waiter yet, or returns
/// null when every row is taken. The caller holds the guard and starts the
/// row's worker.
///
/// ```zig
/// const slot = resolutions.add(host, io) orelse return error.ResolutionLimitReached;
/// ```
pub fn add(self: *Resolutions, host: HostName, io: std.Io) ?Slot {
    for (&self.phase, 0..) |*phase, index| {
        if (phase.load(.monotonic) != .free) {
            continue;
        }

        @memcpy(self.host[index][0..host.bytes.len], host.bytes);
        self.host_len[index] = @intCast(host.bytes.len);
        self.io[index] = io;
        self.waiters[index] = 0;
        phase.store(.resolving, .release);
        return @enumFromInt(index);
    }

    return null;
}

/// Frees a row no tunnel waits for and whose worker is done. The caller
/// holds the guard.
///
/// ```zig
/// resolutions.remove(slot);
/// ```
pub fn remove(self: *Resolutions, slot: Slot) void {
    const index = @intFromEnum(slot);
    std.debug.assert(self.waiters[index] == 0);
    self.phase[index].store(.free, .release);
}

/// Counts the rows in `phase`, without the guard.
///
/// ```zig
/// const blocked = resolutions.count(.resolving);
/// ```
pub fn count(self: *const Resolutions, phase: Phase) u32 {
    var total: u32 = 0;
    for (&self.phase) |*row| {
        total += @intFromBool(row.load(.acquire) == phase);
    }

    return total;
}

fn sameIo(left: std.Io, right: std.Io) bool {
    return left.userdata == right.userdata and left.vtable == right.vtable;
}
