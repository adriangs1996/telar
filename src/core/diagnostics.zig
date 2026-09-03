//! Development-only performance diagnostics.
//!
//! Release builds compile every call site away. Debug builds write JSON Lines
//! beside the runtime socket, never terminal or PTY contents.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

const root = @import("root");

/// Debug builds always collect diagnostics. An optimized build opts in by
/// declaring `pub const telar_diagnostics = true` at its root, which the
/// `-Ddiagnostics` build option does for the shipped binary, so exterior
/// measurements can read the counters without measuring safety checks.
pub const enabled = builtin.mode == .Debug or
    (@hasDecl(root, "telar_diagnostics") and root.telar_diagnostics);
pub const interval_ns: u64 = std.time.ns_per_s;

pub const Timing = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn observe(timing: *Timing, elapsed_ns: u64) void {
        timing.count += 1;
        timing.total_ns +|= elapsed_ns;
        timing.max_ns = @max(timing.max_ns, elapsed_ns);
    }

    pub fn average(timing: Timing) u64 {
        return if (timing.count == 0) 0 else timing.total_ns / timing.count;
    }

    /// Folds samples collected elsewhere into this timing, so a per-object
    /// timing drained on a boundary can feed one process-wide aggregate.
    ///
    /// ```zig
    /// metrics.graphics_freeze.merge(counts.freeze);
    /// ```
    pub fn merge(timing: *Timing, other: Timing) void {
        timing.count +|= other.count;
        timing.total_ns +|= other.total_ns;
        timing.max_ns = @max(timing.max_ns, other.max_ns);
    }
};

pub const Sink = struct {
    file: if (enabled) ?File else void = if (enabled) null else {},

    pub fn init(io: Io, endpoint: []const u8, suffix: []const u8) Sink {
        if (!enabled) {
            return .{};
        }

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}.{s}.log", .{ endpoint, suffix }) catch
            return .{};
        const file = Io.Dir.createFileAbsolute(io, path, .{
            .exclusive = true,
            .permissions = File.Permissions.fromMode(0o600),
        }) catch return .{};
        return .{ .file = file };
    }

    pub fn deinit(sink: *Sink, io: Io) void {
        if (!enabled) {
            return;
        }
        if (sink.file) |file| {
            file.close(io);
        }
        sink.file = null;
    }

    pub fn available(sink: *const Sink) bool {
        return if (enabled) sink.file != null else false;
    }

    pub fn write(sink: *Sink, io: Io, bytes: []const u8) !void {
        if (!enabled or sink.file == null) {
            return;
        }
        try sink.file.?.writeStreamingAll(io, bytes);
    }
};

pub fn now(io: Io) u64 {
    if (!enabled) {
        return 0;
    }
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

pub fn elapsed(start_ns: u64, end_ns: u64) u64 {
    return end_ns -| start_ns;
}

pub fn waitForTick(io: Io) anyerror!void {
    try io.sleep(.fromNanoseconds(interval_ns), .awake);
}

/// Which of the three budgets currently owns this thread's heap traffic.
pub const Path = enum(u2) {
    interactive,
    media,
    observation,
    other,
};

const path_count = std.meta.tags(Path).len;

threadlocal var current_path: Path = .other;
threadlocal var terminal_allocation_scope: bool = false;

pub const Guard = struct {
    previous: Path,

    pub fn restore(guard: Guard) void {
        if (!enabled) {
            return;
        }
        current_path = guard.previous;
    }
};

pub fn enter(path: Path) Guard {
    if (!enabled) {
        return .{ .previous = .other };
    }
    const previous = current_path;
    current_path = path;
    return .{ .previous = previous };
}

pub const TerminalAllocationGuard = struct {
    previous: bool,

    pub fn restore(guard: TerminalAllocationGuard) void {
        if (!enabled) {
            return;
        }
        terminal_allocation_scope = guard.previous;
    }
};

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

const Counter = if (enabled) std.atomic.Value(u64) else void;
const counter_init: Counter = if (enabled) .init(0) else {};

fn add(counter: *Counter, n: u64) void {
    if (!enabled) {
        return;
    }
    _ = counter.fetchAdd(n, .monotonic);
}

fn sub(counter: *Counter, n: u64) void {
    if (!enabled) {
        return;
    }
    _ = counter.fetchSub(n, .monotonic);
}

fn load(counter: *const Counter) u64 {
    if (!enabled) {
        return 0;
    }
    return counter.load(.monotonic);
}

/// Counting wrapper around the process GPA. Debug builds attribute every
/// alloc/free to the thread's current `Path`. Release returns the child
/// unchanged, so the interactive path pays nothing.
pub const Heap = struct {
    child: Allocator,
    live_bytes: Counter = counter_init,
    live_allocs: Counter = counter_init,
    allocs: Counter = counter_init,
    frees: Counter = counter_init,
    alloc_bytes: Counter = counter_init,
    path_allocs: [path_count]Counter = @splat(counter_init),
    path_alloc_bytes: [path_count]Counter = @splat(counter_init),
    interactive_vt_allocs: Counter = counter_init,
    interactive_vt_alloc_bytes: Counter = counter_init,

    pub const Snapshot = struct {
        live_bytes: u64 = 0,
        live_allocs: u64 = 0,
        allocs: u64 = 0,
        frees: u64 = 0,
        alloc_bytes: u64 = 0,
        interactive_allocs: u64 = 0,
        interactive_alloc_bytes: u64 = 0,
        interactive_vt_allocs: u64 = 0,
        interactive_vt_alloc_bytes: u64 = 0,
        media_allocs: u64 = 0,
        media_alloc_bytes: u64 = 0,
        observation_allocs: u64 = 0,
        observation_alloc_bytes: u64 = 0,
        other_allocs: u64 = 0,
        other_alloc_bytes: u64 = 0,
    };

    pub fn init(child: Allocator) Heap {
        return .{ .child = child };
    }

    pub fn allocator(heap: *Heap) Allocator {
        if (!enabled) {
            return heap.child;
        }
        return .{
            .ptr = heap,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn snapshot(heap: *const Heap) Snapshot {
        return .{
            .live_bytes = load(&heap.live_bytes),
            .live_allocs = load(&heap.live_allocs),
            .allocs = load(&heap.allocs),
            .frees = load(&heap.frees),
            .alloc_bytes = load(&heap.alloc_bytes),
            .interactive_allocs = load(&heap.path_allocs[@intFromEnum(Path.interactive)]),
            .interactive_alloc_bytes = load(&heap.path_alloc_bytes[@intFromEnum(Path.interactive)]),
            .interactive_vt_allocs = load(&heap.interactive_vt_allocs),
            .interactive_vt_alloc_bytes = load(&heap.interactive_vt_alloc_bytes),
            .media_allocs = load(&heap.path_allocs[@intFromEnum(Path.media)]),
            .media_alloc_bytes = load(&heap.path_alloc_bytes[@intFromEnum(Path.media)]),
            .observation_allocs = load(&heap.path_allocs[@intFromEnum(Path.observation)]),
            .observation_alloc_bytes = load(&heap.path_alloc_bytes[@intFromEnum(Path.observation)]),
            .other_allocs = load(&heap.path_allocs[@intFromEnum(Path.other)]),
            .other_alloc_bytes = load(&heap.path_alloc_bytes[@intFromEnum(Path.other)]),
        };
    }

    fn recordAlloc(heap: *Heap, len: usize) void {
        add(&heap.live_bytes, len);
        add(&heap.live_allocs, 1);
        add(&heap.allocs, 1);
        add(&heap.alloc_bytes, len);
        const path = @intFromEnum(current_path);
        add(&heap.path_allocs[path], 1);
        add(&heap.path_alloc_bytes[path], len);
        if (current_path == .interactive and terminal_allocation_scope) {
            add(&heap.interactive_vt_allocs, 1);
            add(&heap.interactive_vt_alloc_bytes, len);
        }
    }

    fn recordGrow(heap: *Heap, delta: usize) void {
        add(&heap.live_bytes, delta);
        add(&heap.alloc_bytes, delta);
        add(&heap.path_alloc_bytes[@intFromEnum(current_path)], delta);
        if (current_path == .interactive and terminal_allocation_scope) {
            add(&heap.interactive_vt_alloc_bytes, delta);
        }
    }

    fn recordShrink(heap: *Heap, delta: usize) void {
        sub(&heap.live_bytes, delta);
    }

    fn recordFree(heap: *Heap, len: usize) void {
        sub(&heap.live_bytes, len);
        sub(&heap.live_allocs, 1);
        add(&heap.frees, 1);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const heap: *Heap = @ptrCast(@alignCast(context));
        const result = heap.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        heap.recordAlloc(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const heap: *Heap = @ptrCast(@alignCast(context));
        if (!heap.child.rawResize(memory, alignment, new_len, ret_addr)) {
            return false;
        }
        if (new_len > memory.len) {
            heap.recordGrow(new_len - memory.len);
        }
        if (new_len < memory.len) {
            heap.recordShrink(memory.len - new_len);
        }
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const heap: *Heap = @ptrCast(@alignCast(context));
        const result = heap.child.rawRemap(memory, alignment, new_len, ret_addr) orelse
            return null;
        if (new_len > memory.len) {
            heap.recordGrow(new_len - memory.len);
        }
        if (new_len < memory.len) {
            heap.recordShrink(memory.len - new_len);
        }
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const heap: *Heap = @ptrCast(@alignCast(context));
        heap.child.rawFree(memory, alignment, ret_addr);
        heap.recordFree(memory.len);
    }
};

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
    const file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return 0;
    defer file.close();
    const read = file.read(&buffer) catch return 0;
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
