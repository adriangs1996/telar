//! Development-only performance diagnostics.
//!
//! Release builds compile every call site away. Debug builds write JSON Lines
//! beside the runtime socket, never terminal or PTY contents.

const builtin = @import("builtin");
const root = @import("root");
const std = @import("std");
const Guard = @import("Guard.zig");
const TerminalAllocationGuard = @import("TerminalAllocationGuard.zig");
const Timing = @import("Timing.zig");
const Heap = @import("Heap.zig");

/// Debug builds always collect diagnostics. An optimized build opts in by
/// declaring `pub const telar_diagnostics = true` at its root, which the
/// `-Ddiagnostics` build option does for the shipped binary, so exterior
/// measurements can read the counters without measuring safety checks.
pub const enabled = builtin.mode == .Debug or
    (@hasDecl(root, "telar_diagnostics") and root.telar_diagnostics);

pub fn now(io: std.Io) u64 {
    if (!enabled) {
        return 0;
    }
    const timestamp = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

pub fn elapsed(start_ns: u64, end_ns: u64) u64 {
    return end_ns -| start_ns;
}

pub fn waitForTick(io: std.Io) anyerror!void {
    try io.sleep(.fromNanoseconds(std.time.ns_per_s), .awake);
}

/// Which of the three budgets currently owns this thread's heap traffic.
pub const Path = enum(u2) {
    interactive,
    media,
    observation,
    other,
};

pub const path_count = std.meta.tags(Path).len;

pub threadlocal var current_path: Path = .other;
pub threadlocal var terminal_allocation_scope: bool = false;

pub fn enter(path: Path) Guard {
    if (!enabled) {
        return .{ .previous = .other };
    }
    const previous = current_path;
    current_path = path;
    return .{ .previous = previous };
}

/// Attributes allocations made by the external terminal emulator while
/// preserving their interactive-path total. Debug telemetry can then
/// distinguish VT state growth from Telar-owned transient allocation.
pub fn enterTerminalAllocations() TerminalAllocationGuard {
    if (!enabled) {
        return .{ .previous = false };
    }
    const previous = terminal_allocation_scope;
    terminal_allocation_scope = true;
    return .{ .previous = previous };
}

pub const Counter = if (enabled) std.atomic.Value(u64) else void;
pub const counter_init: Counter = if (enabled) .init(0) else {};

pub fn add(counter: *Counter, n: u64) void {
    if (!enabled) {
        return;
    }
    _ = counter.fetchAdd(n, .monotonic);
}

pub fn sub(counter: *Counter, n: u64) void {
    if (!enabled) {
        return;
    }
    _ = counter.fetchSub(n, .monotonic);
}

pub fn load(counter: *const Counter) u64 {
    if (!enabled) {
        return 0;
    }
    return counter.load(.monotonic);
}

/// Resident set of this process, not the host. Zero when the platform
/// cannot sample it.
pub fn rssBytes() u64 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => rssDarwin(),
        .linux => rssLinux(),
        else => 0,
    };
}

fn rssDarwin() u64 {
    if (builtin.os.tag != .macos and builtin.os.tag != .ios and
        builtin.os.tag != .tvos and builtin.os.tag != .watchos and
        builtin.os.tag != .visionos)
    {
        return 0;
    }
    const task_port = std.c.mach_task_self();
    if (task_port == std.c.TASK.NULL) {
        return 0;
    }
    var info_count = std.c.TASK.VM.INFO_COUNT;
    var vm_info: std.c.task_vm_info_data_t = undefined;
    if (std.c.task_info(
        task_port,
        std.c.TASK.VM.INFO,
        @ptrCast(&vm_info),
        &info_count,
    ) != 0) {
        return 0;
    }
    return vm_info.resident_size;
}

fn rssLinux() u64 {
    if (builtin.os.tag != .linux) {
        return 0;
    }
    var buffer: [128]u8 = undefined;
    const file = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return 0;
    defer _ = std.posix.system.close(file);

    const read = std.posix.read(file, &buffer) catch return 0;
    var tokens = std.mem.tokenizeScalar(u8, buffer[0..read], ' ');
    _ = tokens.next() orelse return 0;
    const resident = tokens.next() orelse return 0;
    const pages = std.fmt.parseInt(u64, resident, 10) catch return 0;
    return pages * std.heap.pageSize();
}

test "timings retain count, average, and worst sample" {
    var timing: Timing = .{};
    timing.observe(10);
    timing.observe(30);
    try std.testing.expectEqual(@as(u64, 2), timing.count);
    try std.testing.expectEqual(@as(u64, 20), timing.average());
    try std.testing.expectEqual(@as(u64, 30), timing.max_ns);
}

test "merged timings add counts and keep the worst sample" {
    var timing: Timing = .{};
    timing.observe(10);
    var other: Timing = .{};
    other.observe(30);
    other.observe(20);
    timing.merge(other);
    try std.testing.expectEqual(@as(u64, 3), timing.count);
    try std.testing.expectEqual(@as(u64, 20), timing.average());
    try std.testing.expectEqual(@as(u64, 30), timing.max_ns);
}

test "heap tracks live bytes and frees them" {
    if (!enabled) {
        return;
    }
    var heap = Heap.init(std.testing.allocator);
    const gpa = heap.allocator();
    const bytes = try gpa.alloc(u8, 32);
    const live = heap.snapshot();
    try std.testing.expectEqual(@as(u64, 32), live.live_bytes);
    try std.testing.expectEqual(@as(u64, 1), live.live_allocs);
    try std.testing.expectEqual(@as(u64, 1), live.allocs);
    try std.testing.expectEqual(@as(u64, 32), live.alloc_bytes);
    gpa.free(bytes);
    const after = heap.snapshot();
    try std.testing.expectEqual(@as(u64, 0), after.live_bytes);
    try std.testing.expectEqual(@as(u64, 0), after.live_allocs);
    try std.testing.expectEqual(@as(u64, 1), after.frees);
}

test "heap attributes allocations to the entered path" {
    if (!enabled) {
        return;
    }
    var heap = Heap.init(std.testing.allocator);
    const gpa = heap.allocator();
    {
        const path = enter(.observation);
        defer path.restore();
        const bytes = try gpa.alloc(u8, 8);
        defer gpa.free(bytes);
        const nested = enter(.interactive);
        defer nested.restore();
        {
            const terminal = enterTerminalAllocations();
            defer terminal.restore();
            const extra = try gpa.alloc(u8, 4);
            defer gpa.free(extra);
        }
        const owned = try gpa.alloc(u8, 2);
        defer gpa.free(owned);
    }
    const snap = heap.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.observation_allocs);
    try std.testing.expectEqual(@as(u64, 8), snap.observation_alloc_bytes);
    try std.testing.expectEqual(@as(u64, 2), snap.interactive_allocs);
    try std.testing.expectEqual(@as(u64, 6), snap.interactive_alloc_bytes);
    try std.testing.expectEqual(@as(u64, 1), snap.interactive_vt_allocs);
    try std.testing.expectEqual(@as(u64, 4), snap.interactive_vt_alloc_bytes);
    try std.testing.expectEqual(@as(u64, 0), snap.media_allocs);
}

test "process RSS is nonzero after a live allocation" {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return,
    }
    const bytes = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 1);
    try std.testing.expect(rssBytes() > 0);
}
