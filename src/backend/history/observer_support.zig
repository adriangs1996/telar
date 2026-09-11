//! Bounded, asynchronous observation of one pane's terminal stream.
//!
//! The interactive emulator owns what the user sees. This observer owns a
//! second, disposable emulator used only to recover submitted commands. Raw
//! input, output, resize and exit events are copied into a double buffer by
//! the runtime thread and consumed in order by one observation actor. Kitty
//! graphics and glyph APCs are disabled here: history needs their framing,
//! not their payload decoding or storage.

const StatsType = @import("Stats.zig");

const ObserverType = @import("Observer.zig");
const Input = @import("Input.zig");
const Output = @import("Output.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ClockType = @import("Clock.zig");
const TableType = @import("telar-core").Table;
const SignalType = @import("telar-core").Signal;
const vt = @import("ghostty-vt");
const std = @import("std");
const CommandType = @import("Command.zig");
const StatusType = @import("telar-core").Status;
const AgentProviderType = @import("telar-core").AgentProvider;
const CodexTestSink = @import("CodexTestSink.zig");

pub const batch_bytes = 4 * 16 * 1024;
pub const batch_events = 512;

/// An unchanged screen signal is handed over again after this long, so the
/// runtime refreshes its screen evidence well before that evidence expires.
pub const signal_refresh_ms: i64 = 15 * 1000;

pub const Stats = @import("Stats.zig");

pub const Initialization = @import("Initialization.zig");

pub const InputObservation = @import("ObserverInputObservation.zig");

pub const OutputObservation = @import("ObserverOutputObservation.zig");

pub const Processing = @import("Processing.zig");

pub const Event = union(enum) {
    input: Input,
    output: Output,
    resize: TerminalSizeType,
    shell_exit: struct {
        clock: ClockType,
        exit_code: i32,
    },
    interrupt: ClockType,
};

pub const Observer = @import("Observer.zig");

/// Combines the manifest phrases visible on screen with the prompt-glyph scan.
/// A visible blocked phrase stands. An agent whose manifest declares its own
/// ready prompt is not subject to the generic glyph scan; for the rest the
/// glyph scan decides readiness and the phrases only confirm identity.
pub fn mergeSignals(table: *const TableType, phrases: ?SignalType, prompt: ?SignalType) ?SignalType {
    const signal = phrases orelse return prompt;

    if (signal.status == .blocked or table.declaresReadyPrompt(signal.provider)) {
        return signal;
    }

    var result = prompt orelse return signal;
    result.identity_confirmed = signal.provider == result.provider and signal.identity_confirmed;
    return result;
}

pub fn vtResize(size: TerminalSizeType) vt.Terminal.Resize {
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
    var observer: ObserverType = undefined;
    const size: TerminalSizeType = .{
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

        pub fn emit(collector: *@This(), command: CommandType) void {
            collector.len = @min(command.bytes.len, collector.bytes.len);
            @memcpy(collector.bytes[0..collector.len], command.bytes[0..collector.len]);
        }
    };
    var collector: Collector = .{};
    const started: ClockType = .{ .real_ms = 10, .awake_ns = 100 };
    observer.queueOutput(.{ .bytes = "$ ", .shell_foreground = true, .clock = started });
    observer.queueInput(.{ .bytes = "echo isolated\r", .shell_foreground = true, .clock = started });
    observer.queueOutput(.{ .bytes = "echo isolated\r\n", .shell_foreground = false, .clock = started });
    observer.queueShellExit(.{ .real_ms = 20, .awake_ns = 500 }, 0);
    try std.testing.expect(observer.seal());
    var stats: StatsType = .{};
    observer.processSealed(.{ .cwd = null, .current_size = size, .stats = &stats }, &collector);
    observer.finishSealed();

    try std.testing.expectEqualStrings("echo isolated", collector.bytes[0..collector.len]);
    try std.testing.expectEqual(@as(u64, "echo isolated\r".len), stats.input_bytes);
}

test "overflow marks the observer for a counted reset" {
    var observer: ObserverType = undefined;
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
    const size: TerminalSizeType = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    const signal = (try agentSignalForOutput(
        "Working (1s, esc to interrupt)\r\x1b[2K\xe2\x9d\xaf ",
        size,
    )).?;
    try std.testing.expectEqual(StatusType.ready, signal.status);
    try std.testing.expectEqual(AgentProviderType.claude, signal.provider);
    try std.testing.expect(!signal.identity_confirmed);
    try std.testing.expect(signal.ready_confirmed);
}

test "a raw Claude prompt with a hidden cursor is not ready" {
    const size: TerminalSizeType = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    try std.testing.expect(try agentSignalForOutput("\x1b[?25l\xe2\x9d\xaf ", size) == null);
}

test "Claude software cursor confirms readiness while the terminal cursor is hidden" {
    const size: TerminalSizeType = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    const signal = (try agentSignalForOutput(
        "\x1b[?25l\xe2\x9d\xaf \x1b[7my\x1b[27m ma\xc3\xb1ana ?\r\nstatus",
        size,
    )).?;
    try std.testing.expectEqual(StatusType.ready, signal.status);
    try std.testing.expectEqual(AgentProviderType.claude, signal.provider);
    try std.testing.expect(signal.ready_confirmed);
}

test "an inverse status row does not revive a stale Claude prompt" {
    const size: TerminalSizeType = .{
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

fn agentSignalForOutput(output: []const u8, size: TerminalSizeType) !?SignalType {
    var observer: ObserverType = undefined;
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = size });
    defer observer.deinit();

    const Noop = struct {
        pub fn emit(_: *@This(), _: CommandType) void {}
    };
    var noop: Noop = .{};
    observer.queueOutput(.{ .bytes = output, .shell_foreground = false, .clock = .{ .real_ms = 1, .awake_ns = 1 } });
    try std.testing.expect(observer.seal());
    var stats: StatsType = .{};
    observer.processSealed(.{ .cwd = null, .current_size = size, .stats = &stats }, &noop);
    observer.finishSealed();
    return if (stats.agent_observation) |observation| observation.signal else null;
}

test "Codex transcript quotes do not keep the idle composer working or blocked" {
    for ([_][]const u8{
        "The output contains Working (12s, esc to interrupt).",
        "Do you want to proceed? Yes, and don't ask again.",
    }) |quote| {
        var bytes: [1024]u8 = undefined;
        const output = try std.fmt.bufPrint(&bytes, "{s}\r\n\r\n\xe2\x94\x80 Worked for 12s \xe2\x94\x80\r\n\r\n\xe2\x80\xba Ask Codex to do anything\x1b[3G", .{quote});
        const signal = (try agentSignalForOutput(output, codex_test_size)).?;
        try std.testing.expectEqual(AgentProviderType.codex, signal.provider);
        try std.testing.expectEqual(StatusType.ready, signal.status);
        try std.testing.expect(signal.ready_confirmed);
    }
}

const codex_test_size: TerminalSizeType = .{ .cols = 100, .rows = 16, .cell_width_px = 0, .cell_height_px = 0 };

fn codexTestBatch(observer: *ObserverType, bytes: []const u8, now_ms: i64) !StatsType {
    observer.queueOutput(.{ .bytes = bytes, .shell_foreground = false, .clock = .{ .real_ms = now_ms, .awake_ns = @intCast(now_ms * 1_000_000) } });
    try std.testing.expect(observer.seal());
    var stats: StatsType = .{};
    var sink: CodexTestSink = .{};
    observer.processSealed(.{ .cwd = null, .current_size = codex_test_size, .stats = &stats, .provider = .codex }, &sink);
    observer.finishSealed();
    return stats;
}

test "Codex synchronized repaint never publishes its intermediate idle prompt" {
    var observer: ObserverType = undefined;
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = codex_test_size });
    defer observer.deinit();

    _ = try codexTestBatch(&observer, "\x1b[1;1HWorking (1s, esc to interrupt)\x1b[4;1H\xe2\x80\xba Ask Codex to do anything\x1b[4;3H", 100);
    const partial = try codexTestBatch(&observer, "\x1b[?2026h\x1b[1;1H\x1b[2K\x1b[4;3H", 200);
    try std.testing.expect(partial.agent_observation == null);

    const complete = try codexTestBatch(&observer, "\x1b[1;1HWorking (2s, esc to interrupt)\x1b[4;3H\x1b[?2026l", 201);
    if (complete.agent_observation) |observation| {
        try std.testing.expectEqual(StatusType.working, observation.signal.status);
    }
}

test "Codex repaints preserve the PTY timestamp and reconsider an unchanged ready screen" {
    var observer: ObserverType = undefined;
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = codex_test_size });
    defer observer.deinit();

    const first = try codexTestBatch(&observer, "\xe2\x80\xba Ask Codex to do anything\x1b[3G", 100);
    try std.testing.expectEqual(@as(i64, 100), first.agent_observation.?.observed_at_ms);
    const repeated = try codexTestBatch(&observer, "\x1b[3G", 101);
    try std.testing.expectEqual(@as(i64, 101), repeated.agent_observation.?.observed_at_ms);

    observer.queueInput(.{ .bytes = "next turn\r", .shell_foreground = false, .clock = .{ .real_ms = 20_000, .awake_ns = 20_000_000_000 } });
    try std.testing.expect(observer.seal());
    var stats: StatsType = .{};
    var sink: CodexTestSink = .{};
    observer.processSealed(.{ .cwd = null, .current_size = codex_test_size, .stats = &stats, .provider = .codex }, &sink);
    observer.finishSealed();
    try std.testing.expect(stats.agent_observation == null);
}

test "every byte boundary of a Codex synchronized redraw preserves working until completion" {
    const initial = "\x1b[1;1HWorking (1s)\x1b[4;1H\xe2\x80\xba Ask Codex to do anything\x1b[4;3H";
    const repaint = "\x1b[?2026h\x1b[1;1H\x1b[2K\x1b[4;3H\x1b[1;1H\xe2\x80\xa2 Thinking (2s)\x1b[4;3H\x1b[?2026l";
    for (0..repaint.len + 1) |split| {
        var observer: ObserverType = undefined;
        try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = codex_test_size });
        defer observer.deinit();
        _ = try codexTestBatch(&observer, initial, 100);

        const first = try codexTestBatch(&observer, repaint[0..split], 200);
        const second = try codexTestBatch(&observer, repaint[split..], 201);
        for ([_]StatsType{ first, second }) |stats| {
            if (stats.agent_observation) |observation| {
                try std.testing.expectEqual(StatusType.working, observation.signal.status);
            }
        }

        const idle = try codexTestBatch(&observer, "\x1b[?2026h\x1b[1;1H\x1b[2K\x1b[4;3H\x1b[?2026l", 300);
        try std.testing.expect(idle.agent_observation.?.signal.ready_confirmed);
    }
}

test "Codex transcript placeholders without a live composer never prove readiness" {
    for ([_][]const u8{
        "The placeholder is Ask Codex to do anything.",
        "\xe2\x80\xba Ask Codex to do anything\r\nThis is a quoted transcript.",
    }) |output| {
        try std.testing.expect(try agentSignalForOutput(output, codex_test_size) == null);
    }
}

test "observation loss cannot manufacture an idle Codex screen from a partial repaint" {
    var observer: ObserverType = undefined;
    try observer.init(.{ .io = std.testing.io, .gpa = std.testing.allocator, .cwd = "/work", .size = codex_test_size });
    defer observer.deinit();
    const flood: [batch_bytes]u8 = @splat('x');
    observer.queueOutput(.{ .bytes = &flood, .shell_foreground = false, .clock = .{ .real_ms = 100, .awake_ns = 100_000_000 } });
    const lost = try codexTestBatch(&observer, "\x1b[4;1H\xe2\x80\xba Ask Codex to do anything\x1b[4;3H", 200);
    try std.testing.expect(lost.reset);
    try std.testing.expect(lost.agent_observation == null);

    const recovered = try codexTestBatch(&observer, "\x1b[1;1HWorking (2s)\x1b[4;3H", 300);
    try std.testing.expectEqual(StatusType.working, recovered.agent_observation.?.signal.status);
    const idle = try codexTestBatch(&observer, "\x1b[1;1H\x1b[2K\x1b[4;3H", 400);
    try std.testing.expect(idle.agent_observation.?.signal.ready_confirmed);
}
