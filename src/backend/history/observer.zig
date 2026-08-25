//! Bounded, asynchronous observation of one pane's terminal stream.
//!
//! The interactive emulator owns what the user sees. This observer owns a
//! second, disposable emulator used only to recover submitted commands. Raw
//! input, output, resize and exit events are copied into a double buffer by
//! the runtime thread and consumed in order by one observation actor. Kitty
//! graphics and glyph APCs are disabled here: history needs their framing,
//! not their payload decoding or storage.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_detection = @import("agent_detection.zig");
const terminal_history = @import("terminal.zig");

const Io = std.Io;
const schema = core.schema;

pub const batch_bytes = 4 * 16 * 1024;
pub const batch_events = 512;

pub const Stats = struct {
    input_bytes: u64 = 0,
    captured: u64 = 0,
    dropped: u64 = 0,
    reset: bool = false,
    failed: bool = false,
    agent_signal: ?agent_detection.Signal = null,
};

const Input = struct {
    offset: u32,
    len: u32,
    shell_foreground: bool,
    clock: terminal_history.Clock,
};

const Output = struct {
    offset: u32,
    len: u32,
    shell_foreground: ?bool,
    clock: terminal_history.Clock,
};

const Event = union(enum) {
    input: Input,
    output: Output,
    resize: schema.TerminalSize,
    shell_exit: struct {
        clock: terminal_history.Clock,
        exit_code: i32,
    },
    interrupt: terminal_history.Clock,
};

const Batch = struct {
    bytes: [batch_bytes]u8 = undefined,
    len: usize = 0,
    events: [batch_events]Event = undefined,
    event_count: usize = 0,
    reset_before: bool = false,

    fn reset(batch: *Batch) void {
        batch.len = 0;
        batch.event_count = 0;
        batch.reset_before = false;
    }

    fn pushBytes(batch: *Batch, bytes: []const u8) ?u32 {
        if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len)
            return null;
        const offset = batch.len;
        @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
        batch.len += bytes.len;
        return @intCast(offset);
    }

    fn pushEvent(batch: *Batch, event: Event) bool {
        if (batch.event_count == batch.events.len) return false;
        batch.events[batch.event_count] = event;
        batch.event_count += 1;
        return true;
    }
};

pub const Observer = struct {
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    tracker: terminal_history.Tracker,
    enabled: bool,
    batches: [2]Batch = .{ .{}, .{} },
    active: u1 = 0,
    worker: ?u1 = null,
    dropped_events: u64 = 0,
    dropped_bytes: u64 = 0,
    resets: u64 = 0,
    failures: u64 = 0,
    detector: agent_detection.Detector = .{},

    pub fn init(
        observer: *Observer,
        io: Io,
        gpa: std.mem.Allocator,
        cwd: []const u8,
        size: schema.TerminalSize,
    ) !void {
        observer.gpa = gpa;
        observer.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
        errdefer observer.terminal.deinit(gpa);
        var handler = observer.terminal.vtHandler();
        handler.apc_handler.enable(.kitty, false);
        handler.apc_handler.enable(.glyph, false);
        observer.stream = .init(.{ .allocator = gpa, .handler = handler });
        errdefer observer.stream.deinit();
        try observer.stream.handler.resize(vtResize(size));
        observer.tracker = try .init(gpa, cwd, &observer.terminal);
        observer.enabled = true;
        observer.batches = .{ .{}, .{} };
        observer.active = 0;
        observer.worker = null;
        observer.dropped_events = 0;
        observer.dropped_bytes = 0;
        observer.resets = 0;
        observer.failures = 0;
        observer.detector = .{};
    }

    pub fn deinit(observer: *Observer) void {
        if (observer.worker) |index| observer.batches[index].reset();
        observer.worker = null;
        if (observer.enabled) {
            observer.tracker.deinit(&observer.terminal);
            observer.stream.deinit();
        }
        observer.terminal.deinit(observer.gpa);
    }

    pub fn queueInput(
        observer: *Observer,
        bytes: []const u8,
        shell_foreground: bool,
        clock: terminal_history.Clock,
    ) void {
        const batch = observer.prepareBytes(bytes) orelse return;
        const offset = batch.pushBytes(bytes) orelse unreachable;
        _ = batch.pushEvent(.{ .input = .{
            .offset = offset,
            .len = @intCast(bytes.len),
            .shell_foreground = shell_foreground,
            .clock = clock,
        } });
    }

    pub fn queueOutput(
        observer: *Observer,
        bytes: []const u8,
        shell_foreground: ?bool,
        clock: terminal_history.Clock,
    ) void {
        const batch = observer.prepareBytes(bytes) orelse return;
        const offset = batch.pushBytes(bytes) orelse unreachable;
        _ = batch.pushEvent(.{ .output = .{
            .offset = offset,
            .len = @intCast(bytes.len),
            .shell_foreground = shell_foreground,
            .clock = clock,
        } });
    }

    pub fn queueResize(observer: *Observer, size: schema.TerminalSize) void {
        observer.pushControl(.{ .resize = size });
    }

    pub fn queueShellExit(
        observer: *Observer,
        clock: terminal_history.Clock,
        exit_code: i32,
    ) void {
        observer.pushControl(.{ .shell_exit = .{ .clock = clock, .exit_code = exit_code } });
    }

    pub fn queueInterrupt(observer: *Observer, clock: terminal_history.Clock) void {
        observer.pushControl(.{ .interrupt = clock });
    }

    pub fn hasPending(observer: *const Observer) bool {
        return observer.worker == null and observer.batches[observer.active].event_count != 0;
    }

    pub fn seal(observer: *Observer) bool {
        if (!observer.hasPending()) return false;
        const sealed = observer.active;
        observer.active ^= 1;
        std.debug.assert(observer.batches[observer.active].event_count == 0);
        observer.worker = sealed;
        return true;
    }

    pub fn finishSealed(observer: *Observer) void {
        const index = observer.worker orelse unreachable;
        observer.batches[index].reset();
        observer.worker = null;
    }

    pub fn processSealed(
        observer: *Observer,
        cwd: ?[]const u8,
        current_size: schema.TerminalSize,
        stats: *Stats,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), terminal_history.Command) void,
    ) void {
        const index = observer.worker orelse return;
        const batch = &observer.batches[index];
        observer.detector.resetSample();
        if (batch.reset_before) {
            const reset_cwd = cwd orelse if (observer.enabled)
                observer.tracker.currentCwd()
            else
                "";
            observer.resetState(reset_cwd, current_size) catch {
                observer.failures +|= 1;
                stats.failed = true;
                return;
            };
            observer.resets +|= 1;
            stats.reset = true;
        } else if (!observer.enabled) {
            stats.failed = true;
            return;
        } else if (cwd) |path| {
            observer.tracker.updateCwd(path);
        }

        for (batch.events[0..batch.event_count]) |event| switch (event) {
            .input => |input| {
                const start: usize = input.offset;
                stats.input_bytes +|= observer.tracker.observeInput(
                    &observer.terminal,
                    batch.bytes[start..][0..input.len],
                    input.shell_foreground,
                    input.clock,
                    context,
                    on_command,
                );
            },
            .output => |output| {
                const start: usize = output.offset;
                observer.observeOutput(
                    batch.bytes[start..][0..output.len],
                    output.clock,
                    output.shell_foreground,
                    context,
                    on_command,
                );
            },
            .resize => |size| observer.stream.handler.resize(vtResize(size)) catch {
                observer.failures +|= 1;
                stats.failed = true;
            },
            .shell_exit => |exit| observer.tracker.shellExited(
                exit.clock,
                exit.exit_code,
                context,
                on_command,
            ),
            .interrupt => |clock| observer.tracker.interrupt(clock, context, on_command),
        };
        stats.agent_signal = observer.detector.signal();
    }

    fn observeOutput(
        observer: *Observer,
        bytes: []const u8,
        clock: terminal_history.Clock,
        shell_foreground: ?bool,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), terminal_history.Command) void,
    ) void {
        observer.detector.observe(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = bytes[offset..];
            const boundary = observer.tracker.commitBoundary(remaining);
            const slice = if (boundary) |len| remaining[0..len] else remaining;
            observer.stream.nextSlice(slice);
            if (boundary != null)
                _ = observer.tracker.captureSubmitted(&observer.terminal) catch {
                    observer.failures +|= 1;
                };
            observer.tracker.observeOutput(
                slice,
                clock,
                shell_foreground,
                context,
                on_command,
            );
            offset += slice.len;
        }
    }

    fn prepareBytes(observer: *Observer, bytes: []const u8) ?*Batch {
        if (bytes.len > batch_bytes) {
            observer.dropActive(bytes.len, 1);
            return null;
        }
        var batch = &observer.batches[observer.active];
        if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len) {
            observer.dropActive(bytes.len, 1);
            batch = &observer.batches[observer.active];
        }
        return batch;
    }

    fn pushControl(observer: *Observer, event: Event) void {
        var batch = &observer.batches[observer.active];
        if (!batch.pushEvent(event)) {
            observer.dropActive(0, 1);
            batch = &observer.batches[observer.active];
            _ = batch.pushEvent(event);
        }
    }

    fn dropActive(observer: *Observer, incoming_bytes: usize, incoming_events: usize) void {
        const batch = &observer.batches[observer.active];
        observer.dropped_events +|= batch.event_count + incoming_events;
        observer.dropped_bytes +|= batch.len + incoming_bytes;
        batch.reset();
        batch.reset_before = true;
    }

    fn resetState(
        observer: *Observer,
        cwd: []const u8,
        size: schema.TerminalSize,
    ) !void {
        observer.tracker.deinit(&observer.terminal);
        observer.stream.deinit();
        observer.enabled = false;
        observer.terminal.fullReset();
        var handler = observer.terminal.vtHandler();
        handler.apc_handler.enable(.kitty, false);
        handler.apc_handler.enable(.glyph, false);
        observer.stream = .init(.{ .allocator = observer.gpa, .handler = handler });
        errdefer observer.stream.deinit();
        try observer.stream.handler.resize(vtResize(size));
        observer.tracker = try .init(observer.gpa, cwd, &observer.terminal);
        observer.enabled = true;
    }
};

fn vtResize(size: schema.TerminalSize) vt.Terminal.Resize {
    return .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
            .width = size.cell_width_px,
            .height = size.cell_height_px,
        } else null,
    };
}

test "input and output are observed in enqueue order" {
    var observer: Observer = undefined;
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    try observer.init(std.testing.io, std.testing.allocator, "/work", size);
    defer observer.deinit();

    const Collector = struct {
        bytes: [64]u8 = undefined,
        len: usize = 0,

        fn capture(collector: *@This(), command: terminal_history.Command) void {
            collector.len = @min(command.bytes.len, collector.bytes.len);
            @memcpy(collector.bytes[0..collector.len], command.bytes[0..collector.len]);
        }
    };
    var collector: Collector = .{};
    const started: terminal_history.Clock = .{ .real_ms = 10, .awake_ns = 100 };
    observer.queueOutput("$ ", true, started);
    observer.queueInput("echo isolated\r", true, started);
    observer.queueOutput("echo isolated\r\n", false, started);
    observer.queueShellExit(.{ .real_ms = 20, .awake_ns = 500 }, 0);
    try std.testing.expect(observer.seal());
    var stats: Stats = .{};
    observer.processSealed(null, size, &stats, &collector, Collector.capture);
    observer.finishSealed();

    try std.testing.expectEqualStrings("echo isolated", collector.bytes[0..collector.len]);
    try std.testing.expectEqual(@as(u64, "echo isolated\r".len), stats.input_bytes);
}

test "overflow marks the observer for a counted reset" {
    var observer: Observer = undefined;
    try observer.init(std.testing.io, std.testing.allocator, "/work", .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    });
    defer observer.deinit();
    const bytes: [batch_bytes]u8 = @splat('x');
    observer.queueOutput(&bytes, true, .{ .real_ms = 1, .awake_ns = 1 });
    observer.queueOutput("overflow", true, .{ .real_ms = 2, .awake_ns = 2 });
    try std.testing.expect(observer.seal());
    try std.testing.expect(observer.dropped_events != 0);
    observer.finishSealed();
}
