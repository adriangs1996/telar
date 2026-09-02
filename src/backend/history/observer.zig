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

pub const Initialization = struct {
    io: Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    size: schema.TerminalSize,
    manifests: *const agent_detection.Table = &core.agent_manifest.builtin_table,
    capture_output: bool = false,
};

pub const InputObservation = struct {
    bytes: []const u8,
    shell_foreground: bool,
    clock: terminal_history.Clock,
};

pub const OutputObservation = struct {
    bytes: []const u8,
    shell_foreground: ?bool,
    clock: terminal_history.Clock,
};

pub const Processing = struct {
    cwd: ?[]const u8,
    current_size: schema.TerminalSize,
    stats: *Stats,
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
    manifests: *const agent_detection.Table = &core.agent_manifest.builtin_table,

    /// Initializes the disposable history emulator and its bounded event
    /// buffers for one pane.
    ///
    /// ```zig
    /// try observer.init(.{ .io = io, .gpa = gpa, .cwd = cwd, .size = size });
    /// ```
    pub fn init(observer: *Observer, initialization: Initialization) !void {
        const io = initialization.io;
        const gpa = initialization.gpa;
        const cwd = initialization.cwd;
        const size = initialization.size;

        observer.gpa = gpa;
        observer.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
        errdefer observer.terminal.deinit(gpa);
        var handler = observer.terminal.vtHandler();
        handler.apc_handler.enable(.kitty, false);
        handler.apc_handler.enable(.glyph, false);
        observer.stream = .init(.{ .allocator = gpa, .handler = handler });
        errdefer observer.stream.deinit();
        try observer.stream.handler.resize(vtResize(size));
        observer.tracker = try .init(gpa, .{
            .cwd = cwd,
            .terminal = &observer.terminal,
            .capture_output = initialization.capture_output,
        });
        observer.enabled = true;
        observer.batches = .{ .{}, .{} };
        observer.active = 0;
        observer.worker = null;
        observer.dropped_events = 0;
        observer.dropped_bytes = 0;
        observer.resets = 0;
        observer.failures = 0;
        observer.detector = .{};
        observer.manifests = initialization.manifests;
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

    /// Copies one input event into the active bounded observation batch.
    ///
    /// ```zig
    /// observer.queueInput(.{ .bytes = bytes, .shell_foreground = true, .clock = clock });
    /// ```
    pub fn queueInput(observer: *Observer, observation: InputObservation) void {
        const batch = observer.prepareBytes(observation.bytes) orelse return;
        const offset = batch.pushBytes(observation.bytes) orelse unreachable;
        _ = batch.pushEvent(.{ .input = .{
            .offset = offset,
            .len = @intCast(observation.bytes.len),
            .shell_foreground = observation.shell_foreground,
            .clock = observation.clock,
        } });
    }

    /// Copies one output event into the active bounded observation batch.
    ///
    /// ```zig
    /// observer.queueOutput(.{ .bytes = bytes, .shell_foreground = foreground, .clock = clock });
    /// ```
    pub fn queueOutput(observer: *Observer, observation: OutputObservation) void {
        const batch = observer.prepareBytes(observation.bytes) orelse return;
        const offset = batch.pushBytes(observation.bytes) orelse unreachable;
        _ = batch.pushEvent(.{ .output = .{
            .offset = offset,
            .len = @intCast(observation.bytes.len),
            .shell_foreground = observation.shell_foreground,
            .clock = observation.clock,
        } });
    }

    pub fn queueResize(observer: *Observer, size: schema.TerminalSize) void {
        observer.pushControl(.{ .resize = size });
    }

    pub fn queueShellExit(observer: *Observer, clock: terminal_history.Clock, exit_code: i32) void {
        observer.pushControl(.{ .shell_exit = .{ .clock = clock, .exit_code = exit_code } });
    }

    pub fn queueInterrupt(observer: *Observer, clock: terminal_history.Clock) void {
        observer.pushControl(.{ .interrupt = clock });
    }

    pub fn hasPending(observer: *const Observer) bool {
        return observer.worker == null and observer.batches[observer.active].event_count != 0;
    }

    pub fn currentCwd(observer: *const Observer) []const u8 {
        if (!observer.enabled) return "";
        return observer.tracker.currentCwd();
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

    /// Replays one sealed batch through the history emulator and emits complete
    /// commands to a statically dispatched sink exposing `emit(Command)`.
    ///
    /// ```zig
    /// observer.processSealed(.{ .cwd = cwd, .current_size = size, .stats = stats }, &sink);
    /// ```
    pub fn processSealed(observer: *Observer, processing: Processing, sink: anytype) void {
        const cwd = processing.cwd;
        const current_size = processing.current_size;
        const stats = processing.stats;

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
                stats.input_bytes +|= observer.tracker.observeInput(.{
                    .terminal = &observer.terminal,
                    .bytes = batch.bytes[start..][0..input.len],
                    .shell_foreground = input.shell_foreground,
                    .clock = input.clock,
                }, sink);
            },
            .output => |output| {
                const start: usize = output.offset;
                observer.observeOutput(.{
                    .bytes = batch.bytes[start..][0..output.len],
                    .clock = output.clock,
                    .shell_foreground = output.shell_foreground,
                }, sink);
            },
            .resize => |size| observer.stream.handler.resize(vtResize(size)) catch {
                observer.failures +|= 1;
                stats.failed = true;
            },
            .shell_exit => |exit| observer.tracker.shellExited(.{
                .clock = exit.clock,
                .exit_code = exit.exit_code,
            }, sink),
            .interrupt => |clock| observer.tracker.interrupt(clock, sink),
        };
        const stream_signal = observer.detector.signal(observer.manifests);
        const screen_signal = claudeReadyPrompt(&observer.terminal);
        stats.agent_signal = if (stream_signal) |signal|
            if (signal.status == .blocked)
                signal
            else if (signal.provider != .codex and screen_signal != null) merged: {
                var result = screen_signal.?;
                result.identity_confirmed = signal.provider == .claude and
                    signal.identity_confirmed;
                break :merged result;
            } else signal
        else
            screen_signal;
    }

    fn observeOutput(observer: *Observer, observation: OutputObservation, sink: anytype) void {
        observer.detector.observe(observation.bytes);
        var offset: usize = 0;
        while (offset < observation.bytes.len) {
            const remaining = observation.bytes[offset..];
            const boundary = observer.tracker.commitBoundary(remaining);
            const slice = if (boundary) |len| remaining[0..len] else remaining;
            observer.stream.nextSlice(slice);
            if (boundary != null)
                _ = observer.tracker.captureSubmitted(&observer.terminal) catch {
                    observer.failures +|= 1;
                };
            observer.tracker.observeOutput(.{
                .bytes = slice,
                .clock = observation.clock,
                .shell_foreground = observation.shell_foreground,
            }, sink);
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

    fn resetState(observer: *Observer, cwd: []const u8, size: schema.TerminalSize) !void {
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
        observer.tracker = try .init(observer.gpa, .{ .cwd = cwd, .terminal = &observer.terminal });
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

/// Claude's prompt glyph is meaningful only in the terminal's current screen.
/// A copy found in raw PTY bytes may have been erased or moved before the batch
/// finished. Claude may use either the terminal cursor or an inverse-video cell
/// as its editor cursor. In both cases the cursor must belong to the prompt row,
/// which excludes the stale input row Claude leaves behind while it is working.
fn claudeReadyPrompt(terminal: *const vt.Terminal) ?agent_detection.Signal {
    const screen = terminal.screens.active;
    const ready = if (terminal.modes.get(.cursor_visible))
        promptBeforeTerminalCursor(screen.cursor.page_pin.*)
    else
        promptWithSoftwareCursor(screen, terminal.rows);
    if (!ready) return null;
    return .{
        .provider = .claude,
        .status = .ready,
        .confidence = 96,
        .ready_confirmed = true,
    };
}

fn promptBeforeTerminalCursor(cursor: vt.Pin) bool {
    const cells = cursor.cells(.left);
    const max_prompt_distance = 8;
    var index = cells.len;
    var distance: usize = 0;
    while (index != 0 and distance < max_prompt_distance) : (distance += 1) {
        index -= 1;
        const cell = cells[index];
        if (!cell.hasText()) continue;
        const codepoint = cell.codepoint();
        if (codepoint == ' ') continue;
        return codepoint == 0x276f;
    }
    return false;
}

fn promptWithSoftwareCursor(screen: *const vt.Screen, rows: u16) bool {
    const max_prompt_rows = 12;
    const first_row = rows - @min(rows, max_prompt_rows);
    for (first_row..rows) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .y = @intCast(y) } }) orelse
            continue;
        const cells = pin.cells(.all);
        var prompt: ?usize = null;
        for (cells, 0..) |*cell, x| {
            if (cell.codepoint() == 0x276f and rowPrefixIsBlank(cells[0..x])) {
                prompt = x;
                continue;
            }
            if (prompt == null or x <= prompt.?) continue;
            if (cell.content_tag == .bg_color_palette or cell.content_tag == .bg_color_rgb)
                return true;
            const cell_style = pin.style(cell);
            if (cell_style.flags.inverse or hasBackground(cell_style.bg_color)) return true;
        }
    }
    return false;
}

fn rowPrefixIsBlank(cells: []const vt.Cell) bool {
    for (cells) |cell| {
        if (cell.hasText() and cell.codepoint() != ' ') return false;
    }
    return true;
}

fn hasBackground(color: vt.Style.Color) bool {
    return switch (color) {
        .none => false,
        .palette, .rgb => true,
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
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = size });
    defer observer.deinit();

    const Collector = struct {
        bytes: [64]u8 = undefined,
        len: usize = 0,

        pub fn emit(collector: *@This(), command: terminal_history.Command) void {
            collector.len = @min(command.bytes.len, collector.bytes.len);
            @memcpy(collector.bytes[0..collector.len], command.bytes[0..collector.len]);
        }
    };
    var collector: Collector = .{};
    const started: terminal_history.Clock = .{ .real_ms = 10, .awake_ns = 100 };
    observer.queueOutput(.{ .bytes = "$ ", .shell_foreground = true, .clock = started });
    observer.queueInput(.{ .bytes = "echo isolated\r", .shell_foreground = true, .clock = started });
    observer.queueOutput(.{ .bytes = "echo isolated\r\n", .shell_foreground = false, .clock = started });
    observer.queueShellExit(.{ .real_ms = 20, .awake_ns = 500 }, 0);
    try std.testing.expect(observer.seal());
    var stats: Stats = .{};
    observer.processSealed(.{ .cwd = null, .current_size = size, .stats = &stats }, &collector);
    observer.finishSealed();

    try std.testing.expectEqualStrings("echo isolated", collector.bytes[0..collector.len]);
    try std.testing.expectEqual(@as(u64, "echo isolated\r".len), stats.input_bytes);
}

test "overflow marks the observer for a counted reset" {
    var observer: Observer = undefined;
    try observer.init(.{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .cwd = "/work",
        .size = .{
            .cols = 40,
            .rows = 8,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
    });
    defer observer.deinit();
    const bytes: [batch_bytes]u8 = @splat('x');
    observer.queueOutput(.{ .bytes = &bytes, .shell_foreground = true, .clock = .{ .real_ms = 1, .awake_ns = 1 } });
    observer.queueOutput(.{ .bytes = "overflow", .shell_foreground = true, .clock = .{ .real_ms = 2, .awake_ns = 2 } });
    try std.testing.expect(observer.seal());
    try std.testing.expect(observer.dropped_events != 0);
    observer.finishSealed();
}

test "Claude readiness comes from the prompt at the visible cursor" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    const signal = (try agentSignalForOutput(
        "Working (1s, esc to interrupt)\r\x1b[2K\xe2\x9d\xaf ",
        size,
    )).?;
    try std.testing.expectEqual(agent_detection.Status.ready, signal.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, signal.provider);
    try std.testing.expect(!signal.identity_confirmed);
    try std.testing.expect(signal.ready_confirmed);
}

test "a raw Claude prompt with a hidden cursor is not ready" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    try std.testing.expect(try agentSignalForOutput("\x1b[?25l\xe2\x9d\xaf ", size) == null);
}

test "Claude software cursor confirms readiness while the terminal cursor is hidden" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    const signal = (try agentSignalForOutput(
        "\x1b[?25l\xe2\x9d\xaf \x1b[7my\x1b[27m ma\xc3\xb1ana ?\r\nstatus",
        size,
    )).?;
    try std.testing.expectEqual(agent_detection.Status.ready, signal.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, signal.provider);
    try std.testing.expect(signal.ready_confirmed);
}

test "an inverse status row does not revive a stale Claude prompt" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    try std.testing.expect(try agentSignalForOutput(
        "\x1b[?25l\xe2\x9d\xaf stale request\r\n\x1b[7mworking\x1b[27m",
        size,
    ) == null);
}

fn agentSignalForOutput(output: []const u8, size: schema.TerminalSize) !?agent_detection.Signal {
    var observer: Observer = undefined;
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = size });
    defer observer.deinit();

    const Noop = struct {
        pub fn emit(_: *@This(), _: terminal_history.Command) void {}
    };
    var noop: Noop = .{};
    observer.queueOutput(.{ .bytes = output, .shell_foreground = false, .clock = .{ .real_ms = 1, .awake_ns = 1 } });
    try std.testing.expect(observer.seal());
    var stats: Stats = .{};
    observer.processSealed(.{ .cwd = null, .current_size = size, .stats = &stats }, &noop);
    observer.finishSealed();
    return stats.agent_signal;
}
