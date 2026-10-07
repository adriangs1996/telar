//! Development-only performance diagnostics.
//!
//! Release builds compile every call site away. Debug builds write JSON Lines
//! beside the runtime socket, never terminal or PTY contents.

const builtin = @import("builtin");
const root = @import("root");
const std = @import("std");
const Guard = @import("Guard.zig");
const TerminalAllocationGuard = @import("TerminalAllocationGuard.zig");

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
    // SAFETY: task_info writes the VM info prefix on success; resident_size is read only after that success.
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
