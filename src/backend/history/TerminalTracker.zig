const TerminalTrackerConfig = @import("TerminalTrackerConfig.zig");
const std = @import("std");
const OscTracker = @import("OscTracker.zig");
const vt = @import("ghostty-vt");
const InputScannerType = @import("InputScanner.zig");
const terminal_ops = @import("terminal.zig");
const TerminalInputObservation = @import("TerminalInputObservation.zig");
const builtin = @import("builtin");
const osc = @import("osc.zig");
const TerminalOutputObservation = @import("TerminalOutputObservation.zig");
const ClockType = @import("Clock.zig");
const CommandType = @import("Command.zig");
const ExitObservation = @import("ExitObservation.zig");
const TerminalCompletion = @import("TerminalCompletion.zig");
const Tracker = @This();

gpa: std.mem.Allocator,
aux: OscTracker,
/// Bounded raw output tail for the running command; null unless output
/// capture is enabled at startup.
output_tail: ?[]u8 = null,
output_len: usize = 0,
output_observed: u64 = 0,
anchor: *vt.Pin,
right_prompt: *vt.Pin,
right_prompt_active: bool = false,
right_prompt_hash: u64 = 0,
/// The shell erased the anchor row while editing and has not painted a
/// prompt to re-anchor at yet.
anchor_erased: bool = false,
phase: Phase = .idle,
input: InputScannerType = .{},
command: ?[:0]const u8 = null,
command_truncated: bool = false,
command_cwd: [std.fs.max_path_bytes]u8 = undefined,
command_cwd_len: usize = 0,
started_at_ms: i64 = 0,
started_awake_ns: i64 = 0,
last_output_awake_ns: i64 = 0,
saw_foreground_child: bool = false,
submissions_armed: u64 = 0,
submissions_captured: u64 = 0,
capture_failures: u64 = 0,
foreground_completions: u64 = 0,
next_input_completions: u64 = 0,
auxiliary_completions: u64 = 0,

pub const Phase = enum {
    idle,
    editing,
    awaiting_commit,
    running,
};

pub const Config = @import("TerminalTrackerConfig.zig");

pub fn init(gpa: std.mem.Allocator, config: TerminalTrackerConfig) !Tracker {
    const terminal = config.terminal;
    const screen = terminal.screens.active;
    const anchor = try screen.pages.trackPin(screen.cursor.page_pin.*);
    errdefer screen.pages.untrackPin(anchor);
    const output_tail: ?[]u8 = if (config.capture_output)
        try gpa.alloc(u8, terminal_ops.max_output_tail_bytes)
    else
        null;
    return .{
        .gpa = gpa,
        .aux = .init(config.cwd),
        .output_tail = output_tail,
        // Allocate the tracked pin once. Starting an edit then only copies
        // the terminal cursor into it, so pane input remains allocation-free.
        .anchor = anchor,
        .right_prompt = try screen.pages.trackPin(screen.cursor.page_pin.*),
    };
}

pub fn deinit(tracker: *Tracker, terminal: *vt.Terminal) void {
    if (tracker.output_tail) |tail| {
        tracker.gpa.free(tail);
    }
    tracker.output_tail = null;
    tracker.freeCommand();
    terminal.screens.active.pages.untrackPin(tracker.right_prompt);
    terminal.screens.active.pages.untrackPin(tracker.anchor);
}

/// Observes one client-to-PTY slice and emits any command whose prior run
/// is proven complete by the new edit.
///
/// ```zig
/// _ = tracker.observeInput(.{ .terminal = terminal, .bytes = bytes, .shell_foreground = true, .clock = clock }, &sink);
/// ```
pub fn observeInput(tracker: *Tracker, observation: TerminalInputObservation, sink: anytype) usize {
    const terminal = observation.terminal;
    const bytes = observation.bytes;
    const shell_foreground = observation.shell_foreground;
    const clock = observation.clock;

    _ = tracker.aux.input(bytes);
    if (!shell_foreground or bytes.len == 0) {
        return 0;
    }

    // A new edit proves the previous command returned control to the shell.
    // Use its last PTY output as the end time so user think-time is excluded.
    if (tracker.phase == .running) {
        if (comptime builtin.mode == .Debug) {
            tracker.next_input_completions += 1;
        }
        var finished = clock;
        if (tracker.last_output_awake_ns >= tracker.started_awake_ns) {
            finished.awake_ns = tracker.last_output_awake_ns;
        }
        tracker.finish(.{ .clock = finished, .exit_code = null, .status = .completed }, sink);
    }
    if (tracker.phase == .awaiting_commit) {
        return bytes.len;
    }

    if (tracker.phase == .idle) {
        tracker.beginEdit(terminal);
    }
    const event = tracker.input.feed(bytes);
    if (event.cancelled) {
        tracker.reset(.idle);
        return bytes.len;
    }
    if (event.submitted and tracker.phase == .editing) {
        if (comptime builtin.mode == .Debug) {
            tracker.submissions_armed += 1;
        }
        tracker.phase = .awaiting_commit;
        tracker.started_at_ms = clock.real_ms;
        tracker.started_awake_ns = clock.awake_ns;
        tracker.last_output_awake_ns = clock.awake_ns;
        tracker.saw_foreground_child = false;
        const cwd = tracker.currentCwd();
        tracker.command_cwd_len = @min(cwd.len, tracker.command_cwd.len);
        @memcpy(tracker.command_cwd[0..tracker.command_cwd_len], cwd[0..tracker.command_cwd_len]);
    }
    return bytes.len;
}

/// Returns the end offset of the first output slice that confirms the
/// submitted line was committed. The LF itself is included.
///
/// ```zig
/// const boundary = tracker.commitBoundary(output) orelse return;
/// ```
pub fn commitBoundary(tracker: *const Tracker, bytes: []const u8) ?usize {
    if (tracker.phase != .awaiting_commit) {
        return null;
    }
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
    return newline + 1;
}

/// Captures the terminal selection after the shell advances to the next
/// line. The tracked anchor survives wrapping and scrollback movement.
///
/// Capture is bounded twice: the selection itself is clamped to the rows
/// that can possibly matter, so the transient allocation cannot grow with
/// scrollback, and the retained command is cut to `max_command_bytes`
/// immediately rather than at emit time.
///
/// ```zig
/// if (try tracker.captureSubmitted(terminal)) {
///     publishCommand();
/// }
/// ```
pub fn captureSubmitted(tracker: *Tracker, terminal: *vt.Terminal) !bool {
    if (tracker.phase != .awaiting_commit) {
        return false;
    }
    const screen = terminal.screens.active;
    const finish_pin = screen.cursor.page_pin.*;
    // A blank anchor row means the shell erased the echo and painted
    // elsewhere without the edit being re-anchored. Whatever follows the
    // anchor is prompt, not command.
    if (tracker.anchor.garbage or finish_pin.before(tracker.anchor.*) or tracker.anchor_erased or terminal_ops.rowIsBlank(tracker.anchor.*)) {
        if (comptime builtin.mode == .Debug) {
            tracker.capture_failures += 1;
        }
        tracker.reset(.idle);
        return false;
    }

    const cols: usize = @max(1, terminal.cols);
    const max_rows = osc.max_command_bytes / cols + 2;
    const clamped_finish = if (tracker.anchor.down(max_rows)) |limit| finish: {
        if (!limit.before(finish_pin)) {
            break :finish finish_pin;
        }
        var limited = limit;
        limited.x = @intCast(cols - 1);
        break :finish limited;
    } else finish_pin;

    const selection_finish = tracker.selectionFinish(clamped_finish);
    const selection: vt.Selection = .init(tracker.anchor.*, selection_finish, false);
    const text = try screen.selectionString(tracker.gpa, .{
        .sel = selection,
        .trim = true,
    });
    if (text.len == 0) {
        if (comptime builtin.mode == .Debug) {
            tracker.capture_failures += 1;
        }
        tracker.gpa.free(text);
        tracker.reset(.idle);
        return false;
    }

    tracker.freeCommand();
    if (text.len > osc.max_command_bytes) {
        const keep = terminal_ops.validPrefixLength(text, osc.max_command_bytes);
        const trimmed = tracker.gpa.dupeZ(u8, text[0..keep]) catch |err| {
            tracker.gpa.free(text);
            return err;
        };
        tracker.gpa.free(text);
        tracker.command = trimmed;
        tracker.command_truncated = true;
    } else {
        tracker.command = text;
        tracker.command_truncated = false;
    }
    tracker.phase = .running;
    if (comptime builtin.mode == .Debug) {
        tracker.submissions_captured += 1;
    }
    return true;
}

/// Observes one PTY output slice and completes commands from OSC markers or
/// foreground-process transitions.
///
/// ```zig
/// tracker.observeOutput(.{ .terminal = terminal, .bytes = bytes, .clock = clock, .shell_foreground = foreground }, &sink);
/// ```
pub fn observeOutput(tracker: *Tracker, observation: TerminalOutputObservation, sink: anytype) void {
    const bytes = observation.bytes;
    const clock = observation.clock;
    const shell_foreground = observation.shell_foreground;

    if (bytes.len != 0) {
        tracker.last_output_awake_ns = clock.awake_ns;
    }
    if (tracker.phase == .editing and bytes.len != 0) {
        tracker.rebaseMovedEdit(observation.terminal);
    }
    if (tracker.phase == .running) {
        tracker.captureOutput(bytes);
    }

    const Relay = struct {
        tracker: *Tracker,
        clock: ClockType,
        sink: @TypeOf(sink),

        pub fn emit(relay: *@This(), value: CommandType) void {
            if (relay.tracker.phase != .running) {
                return;
            }
            if (comptime builtin.mode == .Debug) {
                relay.tracker.auxiliary_completions += 1;
            }
            relay.tracker.finish(.{
                .clock = relay.clock,
                .exit_code = value.exit_code,
                .status = value.status,
            }, relay.sink);
        }
    };
    var relay: Relay = .{ .tracker = tracker, .clock = clock, .sink = sink };
    tracker.aux.feed(.{ .bytes = bytes, .clock = clock }, &relay);

    if (tracker.phase != .running) {
        return;
    }
    if (shell_foreground) |is_shell| {
        if (!is_shell) {
            tracker.saw_foreground_child = true;
        } else if (tracker.saw_foreground_child) {
            if (comptime builtin.mode == .Debug) {
                tracker.foreground_completions += 1;
            }
            tracker.finish(.{ .clock = clock, .exit_code = null, .status = .completed }, sink);
        }
    }
}

/// Completes a running command with the shell's exit code, or resets an
/// incomplete edit when no command reached the running phase.
///
/// ```zig
/// tracker.shellExited(.{ .clock = clock, .exit_code = code }, &sink);
/// ```
pub fn shellExited(tracker: *Tracker, observation: ExitObservation, sink: anytype) void {
    if (tracker.phase == .running) {
        tracker.finish(.{ .clock = observation.clock, .exit_code = observation.exit_code, .status = .completed }, sink);
    } else {
        tracker.reset(.idle);
    }
}

/// Completes a running command as interrupted, or clears an incomplete edit.
///
/// ```zig
/// tracker.interrupt(clock, &sink);
/// ```
pub fn interrupt(tracker: *Tracker, clock: ClockType, sink: anytype) void {
    if (tracker.phase == .running) {
        tracker.finish(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
    } else {
        tracker.reset(.idle);
    }
}

pub fn currentCwd(tracker: *const Tracker) []const u8 {
    return tracker.aux.currentCwd();
}

pub fn updateCwd(tracker: *Tracker, cwd: []const u8) void {
    tracker.aux.updateCwd(cwd);
}

fn beginEdit(tracker: *Tracker, terminal: *vt.Terminal) void {
    tracker.anchor.* = terminal.screens.active.cursor.page_pin.*;
    tracker.anchor.garbage = false;
    tracker.anchor_erased = false;
    tracker.findRightPrompt();
    tracker.input.reset();
    tracker.phase = .editing;
}

fn findRightPrompt(tracker: *Tracker) void {
    tracker.right_prompt_active = false;
    const cells = tracker.anchor.*.cells(.all);
    var blank_columns: usize = 0;
    var x: usize = tracker.anchor.x;
    while (x < cells.len) : (x += 1) {
        if (!cells[x].hasText()) {
            blank_columns += 1;
            continue;
        }
        if (blank_columns < 2) {
            blank_columns = 0;
            continue;
        }
        tracker.right_prompt.* = tracker.anchor.*;
        tracker.right_prompt.x = @intCast(x);
        tracker.right_prompt.garbage = false;
        tracker.right_prompt_hash = terminal_ops.hashCells(tracker.right_prompt.*.cells(.right));
        tracker.right_prompt_active = true;
        return;
    }
}

/// Moves the anchor when the shell relocated the line being edited.
///
/// Two shapes are recognized. Input typed before the shell paints its
/// prompt leaves the anchor row blank or holding a stale kernel echo; the
/// line editor then paints the prompt lower and re-echoes the pending text
/// after it. And a shell that redraws prompt and buffer below asynchronous
/// output, or after a clear-screen, moves them the same way. In both, the
/// edit is re-anchored where the re-echo starts, so the prompt and the
/// rows in between never enter the capture.
fn rebaseMovedEdit(tracker: *Tracker, terminal: *vt.Terminal) void {
    if (tracker.anchor.garbage) {
        return;
    }
    if (!tracker.anchor_erased and terminal_ops.rowIsBlank(tracker.anchor.*)) {
        tracker.anchor_erased = true;
    }

    // The new prompt has to be on screen first, or the anchor would land
    // before it and the prompt would be captured as command text.
    const cursor = terminal.screens.active.cursor.page_pin.*;
    const echo_start = tracker.echoStart(cursor);
    if (echo_start == 0 or terminal_ops.cellsBlank(cursor.cells(.left)[0..echo_start])) {
        return;
    }

    const same_row = cursor.node == tracker.anchor.node and cursor.y == tracker.anchor.y;
    const re_echoed = !same_row and echo_start < cursor.x;
    if (!tracker.anchor_erased and !re_echoed) {
        return;
    }

    tracker.anchor.* = cursor;
    tracker.anchor.garbage = false;
    tracker.anchor.x = echo_start;
    tracker.anchor_erased = false;
    tracker.findRightPrompt();
}

/// The column where the re-echo of the typed text starts on the cursor
/// row, or the cursor column when the text has not been re-echoed yet or
/// cannot be matched.
fn echoStart(tracker: *const Tracker, cursor: vt.Pin) u16 {
    const typed = tracker.input.typedText() orelse return cursor.x;
    if (typed.len == 0 or typed.len > cursor.x) {
        return cursor.x;
    }

    const cells = cursor.cells(.left);
    const start = cursor.x - typed.len;
    for (typed, cells[start..cursor.x]) |byte, cell| {
        if (terminal_ops.cellBlank(cell)) {
            if (byte != ' ') {
                return cursor.x;
            }
            continue;
        }
        if (cell.codepoint() != byte) {
            return cursor.x;
        }
    }

    return @intCast(start);
}

fn selectionFinish(tracker: *const Tracker, fallback: vt.Pin) vt.Pin {
    if (!tracker.right_prompt_active or tracker.right_prompt.garbage) {
        return fallback;
    }
    const right_prompt = tracker.right_prompt.*;
    if (right_prompt.x == 0 or
        !tracker.anchor.*.before(right_prompt) or
        !right_prompt.before(fallback) or
        terminal_ops.hashCells(right_prompt.cells(.right)) != tracker.right_prompt_hash)
    {
        return fallback;
    }
    return right_prompt.left(1);
}

fn finish(tracker: *Tracker, completion: TerminalCompletion, sink: anytype) void {
    const owned = tracker.command orelse {
        tracker.reset(.idle);
        return;
    };
    const command_len = terminal_ops.validPrefixLength(owned, osc.max_command_bytes);
    const duration = @max(@as(i64, 0), completion.clock.awake_ns - tracker.started_awake_ns);
    const output: []const u8 = if (tracker.output_tail) |tail| tail[0..tracker.output_len] else "";
    sink.emit(.{
        .bytes = owned[0..command_len],
        .cwd = tracker.command_cwd[0..tracker.command_cwd_len],
        .started_at_ms = tracker.started_at_ms,
        .duration_ns = duration,
        .exit_code = completion.exit_code,
        .status = completion.status,
        .truncated = tracker.command_truncated,
        .output = output,
        .output_truncated = tracker.output_observed > tracker.output_len,
        .output_observed = tracker.output_observed,
    });
    tracker.reset(.idle);
}

pub fn reset(tracker: *Tracker, phase: Phase) void {
    tracker.freeCommand();
    tracker.phase = phase;
    tracker.input.reset();
    tracker.anchor_erased = false;
    tracker.command_truncated = false;
    tracker.saw_foreground_child = false;
    tracker.output_len = 0;
    tracker.output_observed = 0;
}

/// Keeps the newest bytes of the running command's raw output in the
/// bounded tail: when full, the older half is discarded so the ending -
/// where errors usually are - survives.
pub fn captureOutput(tracker: *Tracker, bytes: []const u8) void {
    const tail = tracker.output_tail orelse return;
    tracker.output_observed +|= bytes.len;
    if (bytes.len >= tail.len) {
        @memcpy(tail, bytes[bytes.len - tail.len ..]);
        tracker.output_len = tail.len;
        return;
    }

    if (tracker.output_len + bytes.len > tail.len) {
        const keep = tail.len / 2;
        const drop = tracker.output_len - keep;
        std.mem.copyForwards(u8, tail[0..keep], tail[drop..tracker.output_len]);
        tracker.output_len = keep;
    }

    @memcpy(tail[tracker.output_len .. tracker.output_len + bytes.len], bytes);
    tracker.output_len += bytes.len;
}

fn freeCommand(tracker: *Tracker) void {
    if (tracker.command) |command| {
        tracker.gpa.free(command);
    }
    tracker.command = null;
}
