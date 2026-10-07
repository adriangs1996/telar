//! Resolving a CONNECT host off the tunnel's thread. The system resolver
//! blocks for as long as it likes and cannot be interrupted, so it runs on
//! a detached worker thread that touches nothing but its row of
//! `Resolutions`. The tunnel waits for the row with its own deadline and
//! with cancellation, and leaves when either ends the wait, while the
//! worker stays inside the resolver.
//!
//! Tunnels asking for one name share its row and its worker, so a host that
//! does not resolve costs one thread however often its clients retry.
const core = @import("telar-core");
const std = @import("std");
const Resolutions = @import("Resolutions.zig");
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;

/// What `resolve` returns instead of addresses.
pub const Error = Resolutions.Failure || std.Io.Cancelable || error{
    /// The name did not resolve by the deadline.
    Timeout,
    /// `Resolutions.capacity` other names were resolving.
    ResolutionLimitReached,
};

/// The stack of a worker thread. 512 KiB is what macOS gives every
/// secondary thread, the kind `getaddrinfo` usually runs on; one call used
/// under 6 KiB of it when measured on macOS 26.
const worker_stack_bytes = 512 * 1024;

/// Resolves `request.host` into `addresses`, each with port 0, and returns
/// how many addresses the name has; only the first `addresses.len` are
/// written. It waits at most until `request.deadline_ms` on the awake clock
/// and stops waiting when its task is canceled; either way the worker keeps
/// its row until the resolver returns. A name that finds every row taken by
/// other names is refused without waiting.
///
/// ```zig
/// var addresses: [Resolutions.max_addresses]std.Io.net.IpAddress = undefined;
/// const found = try name_resolution.resolve(resolutions, .{ .host = host, .io = io, .deadline_ms = deadline_ms }, &addresses);
/// ```
pub fn resolve(resolutions: *Resolutions, request: Request, addresses: *[Resolutions.max_addresses]IpAddress) Error!usize {
    const slot = join(resolutions, request) orelse return error.ResolutionLimitReached;
    defer leave(resolutions, slot);

    try wait(resolutions, slot, request);

    const index = @intFromEnum(slot);
    if (resolutions.failure[index]) |failure| {
        return failure;
    }

    const found = resolutions.found[index];
    const kept = @min(found, addresses.len);
    @memcpy(addresses[0..kept], resolutions.addresses[index][0..kept]);
    return found;
}

/// Which name a tunnel resolves, and until when it waits.
const Request = struct {
    host: HostName,
    io: std.Io,
    /// On the awake clock.
    deadline_ms: i64,
};

/// Asks the system resolver through `getaddrinfo`, the one resolver every
/// libc has. It honors the host's own configuration (`/etc/hosts`, search
/// domains, VPN and split DNS on macOS) and its own timeouts.
///
/// ```zig
/// var resolutions: Resolutions = .{ .resolver = name_resolution.askSystem };
/// ```
pub fn askSystem(host: HostName, addresses: []IpAddress) Resolutions.Failure!usize {
    var name: [HostName.max_len:0]u8 = undefined;
    @memcpy(name[0..host.bytes.len], host.bytes);
    name[host.bytes.len] = 0;

    // One entry per address: without a socket type the list repeats each
    // address for stream, datagram and raw sockets.
    const hints: std.c.addrinfo = .{
        .flags = .{},
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = std.c.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var list: ?*std.c.addrinfo = null;
    while (true) {
        switch (std.c.getaddrinfo(name[0..host.bytes.len :0].ptr, null, &hints, &list)) {
            answered => break,
            .SYSTEM => if (std.posix.errno(-1) != .INTR) {
                return error.Unexpected;
            },
            .ADDRFAMILY, .FAMILY => return error.AddressFamilyUnsupported,
            .AGAIN, .FAIL => return error.NameServerFailure,
            .MEMORY => return error.SystemResources,
            .NODATA, .NONAME => return error.UnknownHostName,
            else => return error.Unexpected,
        }
    }

    defer if (list) |first| {
        std.c.freeaddrinfo(first);
    };

    var found: usize = 0;
    var next = list;
    while (next) |entry| : (next = entry.next) {
        const address = ipAddress(entry.addr orelse continue) orelse continue;
        if (found < addresses.len) {
            addresses[found] = address;
        }

        found += 1;
    }

    return found;
}

/// What `getaddrinfo` returns when it filled the list.
const answered: std.c.EAI = @enumFromInt(0);

fn ipAddress(address: *const std.c.sockaddr) ?IpAddress {
    switch (address.family) {
        std.c.AF.INET => {
            const source: *const std.c.sockaddr.in = @ptrCast(@alignCast(address));
            return .{
                .ip4 = .{
                    .bytes = @bitCast(source.addr),
                    .port = 0,
                },
            };
        },
        std.c.AF.INET6 => {
            const source: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(address));
            return .{
                .ip6 = .{
                    .bytes = source.addr,
                    .port = 0,
                    .flow = source.flowinfo,
                    .interface = .{
                        .index = source.scope_id,
                    },
                },
            };
        },
        else => return null,
    }
}

/// Counts the tunnel as a waiter of its name's row, adding the row and
/// starting its worker when the name was not resolving.
fn join(resolutions: *Resolutions, request: Request) ?Resolutions.Slot {
    resolutions.lock();
    const resolving = resolutions.find(request.host, request.io);
    const slot = resolving orelse resolutions.add(request.host, request.io) orelse {
        resolutions.unlock();
        return null;
    };
    resolutions.waiters[@intFromEnum(slot)] += 1;
    resolutions.unlock();

    if (resolving == null) {
        start(resolutions, slot);
    }

    return slot;
}

/// Stops counting the tunnel. The last waiter of an answered row frees it;
/// a row still resolving stays for its worker, and for the next tunnel that
/// asks for its name.
fn leave(resolutions: *Resolutions, slot: Resolutions.Slot) void {
    const index = @intFromEnum(slot);
    resolutions.lock();
    defer resolutions.unlock();

    resolutions.waiters[index] -= 1;
    if (resolutions.waiters[index] == 0 and resolutions.phase[index].load(.monotonic) == .resolved) {
        resolutions.remove(slot);
    }
}

/// Sleeps until the row's worker answers, the deadline passes or the task
/// is canceled.
fn wait(resolutions: *Resolutions, slot: Resolutions.Slot, request: Request) (error{Timeout} || std.Io.Cancelable)!void {
    const phase = &resolutions.phase[@intFromEnum(slot)];
    const deadline: std.Io.Timeout = .{
        .deadline = .{
            .raw = .fromNanoseconds(@as(i96, request.deadline_ms) * std.time.ns_per_ms),
            .clock = .awake,
        },
    };

    while (phase.load(.acquire) == .resolving) {
        if (now(request.io) >= request.deadline_ms) {
            return error.Timeout;
        }

        try request.io.futexWaitTimeout(Resolutions.Phase, &phase.raw, .resolving, deadline);
    }
}

/// Starts the row's worker on a thread of its own, detached: nothing joins
/// it, because nothing can make the resolver return. A thread the host
/// refuses answers the row with `SystemResources`.
fn start(resolutions: *Resolutions, slot: Resolutions.Slot) void {
    const thread = std.Thread.spawn(
        .{
            .stack_size = worker_stack_bytes,
        },
        work,
        .{ resolutions, slot },
    ) catch {
        finish(resolutions, slot, error.SystemResources);
        return;
    };

    thread.detach();
}

fn work(resolutions: *Resolutions, slot: Resolutions.Slot) void {
    const path = core.enter(.observation);
    defer path.restore();

    const index = @intFromEnum(slot);
    const host: HostName = .{
        .bytes = resolutions.host[index][0..resolutions.host_len[index]],
    };

    finish(resolutions, slot, resolutions.resolver(host, &resolutions.addresses[index]));
}

/// Leaves the worker's answer in its row and wakes the tunnels waiting for
/// it. A row every tunnel gave up on is freed instead, and no Io is used:
/// the service those tunnels belonged to may be gone. While a tunnel still
/// waits, its Io is alive, and it cannot leave before the guard is given
/// back.
fn finish(resolutions: *Resolutions, slot: Resolutions.Slot, answer: Resolutions.Failure!usize) void {
    const index = @intFromEnum(slot);
    resolutions.lock();
    defer resolutions.unlock();

    if (resolutions.waiters[index] == 0) {
        resolutions.remove(slot);
        return;
    }

    if (answer) |found| {
        resolutions.found[index] = found;
        resolutions.failure[index] = null;
    } else |failure| {
        resolutions.failure[index] = failure;
    }

    const phase = &resolutions.phase[index];
    phase.store(.resolved, .release);
    resolutions.io[index].futexWake(Resolutions.Phase, &phase.raw, std.math.maxInt(u32));
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}
