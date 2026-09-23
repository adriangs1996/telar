const std = @import("std");
const OscTracker = @import("OscTracker.zig");
const vt = @import("ghostty-vt");
const InputScanner = @import("InputScanner.zig");
const terminal_ops = @import("terminal.zig");
const TerminalInputObservation = @import("TerminalInputObservation.zig");
const builtin = @import("builtin");
const osc = @import("osc.zig");
const Clock = @import("Clock.zig");
const Command = @import("Command.zig");
const Tracker = @This();

gpa: std.mem.Allocator,
aux: OscTracker,
/// Bounded raw output tail for the running command; null unless output
/// capture is enabled at startup.
output_tail: ?[]u8 = null,
output_len: usize = 0,
output_observed: u64 = 0,
/// Both pins belong to the primary page list for the tracker lifetime.
anchor: *vt.Pin,
right_prompt: *vt.Pin,
right_prompt_active: bool = false,
right_prompt_hash: u64 = 0,
/// The shell erased the anchor row while editing and has not painted a
/// prompt to re-anchor at yet.
anchor_erased: bool = false,
phase: Phase = .idle,
input: InputScanner = .{},
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

pub fn init(gpa: std.mem.Allocator, config: Config) !Tracker {
    const terminal = config.terminal;
    const screen = terminal.screens.get(.primary).?;
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

pub fn deinit(self: *Tracker, terminal: *vt.Terminal) void {
    if (self.output_tail) |tail| {
        self.gpa.free(tail);
    }
    self.output_tail = null;
    self.freeCommand();
    terminal.screens.get(.primary).?.pages.untrackPin(self.right_prompt);
    terminal.screens.get(.primary).?.pages.untrackPin(self.anchor);
}

/// Observes one client-to-PTY slice and emits any command whose prior run
/// is proven complete by the new edit.
///
/// ```zig
/// _ = tracker.observeInput(.{ .terminal = terminal, .bytes = bytes, .shell_foreground = true, .clock = clock }, &sink);
/// ```
pub fn observeInput(self: *Tracker, observation: TerminalInputObservation, sink: anytype) usize {
    const terminal = observation.terminal;
    const bytes = observation.bytes;
    const shell_foreground = observation.shell_foreground;
    const clock = observation.clock;

    _ = self.aux.input(bytes);
    if (!shell_foreground or bytes.len == 0 or terminal.screens.active_key != .primary) {
        return 0;
    }

    // A new edit proves the previous command returned control to the shell.
    // Use its last PTY output as the end time so user think-time is excluded.
    if (self.phase == .running) {
        if (comptime builtin.mode == .Debug) {
            self.next_input_completions += 1;
        }
        var finished = clock;
        if (self.last_output_awake_ns >= self.started_awake_ns) {
            finished.awake_ns = self.last_output_awake_ns;
        }
        self.finish(.{ .clock = finished, .exit_code = null, .status = .completed }, sink);
    }
    if (self.phase == .awaiting_commit) {
        return bytes.len;
    }

    if (self.phase == .idle) {
        self.beginEdit(terminal);
    }
    const event = self.input.feed(bytes);
    if (event.cancelled) {
        self.reset(.idle);
        return bytes.len;
    }
    if (event.submitted and self.phase == .editing) {
        if (comptime builtin.mode == .Debug) {
            self.submissions_armed += 1;
        }
        self.phase = .awaiting_commit;
        self.started_at_ms = clock.real_ms;
        self.started_awake_ns = clock.awake_ns;
        self.last_output_awake_ns = clock.awake_ns;
        self.saw_foreground_child = false;
        const cwd = self.currentCwd();
        self.command_cwd_len = @min(cwd.len, self.command_cwd.len);
        @memcpy(self.command_cwd[0..self.command_cwd_len], cwd[0..self.command_cwd_len]);
    }
    return bytes.len;
}

/// Returns the end offset of the first output slice that confirms the
/// submitted line was committed. The LF itself is included.
///
/// ```zig
/// const boundary = tracker.commitBoundary(output) orelse return;
/// ```
pub fn commitBoundary(self: *const Tracker, bytes: []const u8) ?usize {
    if (self.phase != .awaiting_commit) {
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
pub fn captureSubmitted(self: *Tracker, terminal: *vt.Terminal) !bool {
    if (self.phase != .awaiting_commit) {
        return false;
    }

    if (terminal.screens.active_key != .primary) {
        self.reset(.idle);
        return false;
    }

    const screen = terminal.screens.get(.primary).?;
    const finish_pin = screen.cursor.page_pin.*;
    // A blank anchor row means the shell erased the echo and painted
    // elsewhere without the edit being re-anchored. Whatever follows the
    // anchor is prompt, not command.
    if (self.anchor.garbage or finish_pin.before(self.anchor.*) or self.anchor_erased or terminal_ops.rowIsBlank(self.anchor.*)) {
        if (comptime builtin.mode == .Debug) {
            self.capture_failures += 1;
        }
        self.reset(.idle);
        return false;
    }

    const cols: usize = @max(1, terminal.cols);
    const max_rows = osc.max_command_bytes / cols + 2;
    const clamped_finish = if (self.anchor.down(max_rows)) |limit| finish: {
        if (!limit.before(finish_pin)) {
            break :finish finish_pin;
        }
        var limited = limit;
        limited.x = @intCast(cols - 1);
        break :finish limited;
    } else finish_pin;

    const selection_finish = self.selectionFinish(clamped_finish);
    const selection: vt.Selection = .init(self.anchor.*, selection_finish, false);
    const text = try screen.selectionString(self.gpa, .{
        .sel = selection,
        .trim = true,
    });
    if (text.len == 0) {
        if (comptime builtin.mode == .Debug) {
            self.capture_failures += 1;
        }
        self.gpa.free(text);
        self.reset(.idle);
        return false;
    }

    self.freeCommand();
    if (text.len > osc.max_command_bytes) {
        const keep = terminal_ops.validPrefixLength(text, osc.max_command_bytes);
        const trimmed = self.gpa.dupeZ(u8, text[0..keep]) catch |err| {
            self.gpa.free(text);
            return err;
        };
        self.gpa.free(text);
        self.command = trimmed;
        self.command_truncated = true;
    } else {
        self.command = text;
        self.command_truncated = false;
    }
    self.phase = .running;
    if (comptime builtin.mode == .Debug) {
        self.submissions_captured += 1;
    }
    return true;
}

/// Observes one PTY output slice and completes commands from OSC markers or
/// foreground-process transitions.
///
/// ```zig
/// tracker.observeOutput(.{ .terminal = terminal, .bytes = bytes, .clock = clock, .shell_foreground = foreground }, &sink);
/// ```
pub fn observeOutput(self: *Tracker, observation: TerminalOutputObservation, sink: anytype) void {
    const bytes = observation.bytes;
    const clock = observation.clock;
    const shell_foreground = observation.shell_foreground;

    if (bytes.len != 0) {
        self.last_output_awake_ns = clock.awake_ns;
    }

    // Full-screen application buffers are not shell edits. Their pins belong
    // to another page list and cannot replace a tracked primary-screen pin.
    if (observation.terminal.screens.active_key != .primary and
        (self.phase == .editing or self.phase == .awaiting_commit))
    {
        self.reset(.idle);
    }

    if (self.phase == .editing and bytes.len != 0) {
        self.rebaseMovedEdit(observation.terminal);
    }
    if (self.phase == .running) {
        self.captureOutput(bytes);
    }

    const Relay = struct {
        tracker: *Tracker,
        clock: Clock,
        sink: @TypeOf(sink),

        pub fn emit(relay: *@This(), value: Command) void {
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
    var relay: Relay = .{ .tracker = self, .clock = clock, .sink = sink };
    self.aux.feed(.{ .bytes = bytes, .clock = clock }, &relay);

    if (self.phase != .running) {
        return;
    }
    if (shell_foreground) |is_shell| {
        if (!is_shell) {
            self.saw_foreground_child = true;
        } else if (self.saw_foreground_child) {
            if (comptime builtin.mode == .Debug) {
                self.foreground_completions += 1;
            }
            self.finish(.{ .clock = clock, .exit_code = null, .status = .completed }, sink);
        }
    }
}

/// Completes a running command with the shell's exit code, or resets an
/// incomplete edit when no command reached the running phase.
///
/// ```zig
/// tracker.shellExited(.{ .clock = clock, .exit_code = code }, &sink);
/// ```
pub fn shellExited(self: *Tracker, observation: ExitObservation, sink: anytype) void {
    if (self.phase == .running) {
        self.finish(.{ .clock = observation.clock, .exit_code = observation.exit_code, .status = .completed }, sink);
    } else {
        self.reset(.idle);
    }
}

/// Completes a running command as interrupted, or clears an incomplete edit.
///
/// ```zig
/// tracker.interrupt(clock, &sink);
/// ```
pub fn interrupt(self: *Tracker, clock: Clock, sink: anytype) void {
    if (self.phase == .running) {
        self.finish(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
    } else {
        self.reset(.idle);
    }
}

pub fn currentCwd(self: *const Tracker) []const u8 {
    return self.aux.currentCwd();
}

pub fn updateCwd(self: *Tracker, cwd: []const u8) void {
    self.aux.updateCwd(cwd);
}

fn beginEdit(self: *Tracker, terminal: *vt.Terminal) void {
    self.anchor.* = terminal.screens.get(.primary).?.cursor.page_pin.*;
    self.anchor.garbage = false;
    self.anchor_erased = false;
    self.findRightPrompt();
    self.input.reset();
    self.phase = .editing;
}

fn findRightPrompt(self: *Tracker) void {
    self.right_prompt_active = false;
    const cells = self.anchor.*.cells(.all);
    var blank_columns: usize = 0;
    var x: usize = self.anchor.x;
    while (x < cells.len) : (x += 1) {
        if (!cells[x].hasText()) {
            blank_columns += 1;
            continue;
        }
        if (blank_columns < 2) {
            blank_columns = 0;
            continue;
        }
        self.right_prompt.* = self.anchor.*;
        self.right_prompt.x = @intCast(x);
        self.right_prompt.garbage = false;
        self.right_prompt_hash = terminal_ops.hashCells(self.right_prompt.*.cells(.right));
        self.right_prompt_active = true;
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
fn rebaseMovedEdit(self: *Tracker, terminal: *vt.Terminal) void {
    if (self.anchor.garbage) {
        return;
    }
    if (!self.anchor_erased and terminal_ops.rowIsBlank(self.anchor.*)) {
        self.anchor_erased = true;
    }

    // The new prompt has to be on screen first, or the anchor would land
    // before it and the prompt would be captured as command text.
    const cursor = terminal.screens.get(.primary).?.cursor.page_pin.*;
    const echo_start = self.echoStart(cursor);
    if (echo_start == 0 or terminal_ops.cellsBlank(cursor.cells(.left)[0..echo_start])) {
        return;
    }

    const same_row = cursor.node == self.anchor.node and cursor.y == self.anchor.y;
    const re_echoed = !same_row and echo_start < cursor.x;
    if (!self.anchor_erased and !re_echoed) {
        return;
    }

    self.anchor.* = cursor;
    self.anchor.garbage = false;
    self.anchor.x = echo_start;
    self.anchor_erased = false;
    self.findRightPrompt();
}

/// The column where the re-echo of the typed text starts on the cursor
/// row, or the cursor column when the text has not been re-echoed yet or
/// cannot be matched.
fn echoStart(self: *const Tracker, cursor: vt.Pin) u16 {
    const typed = self.input.typedText() orelse return cursor.x;
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

fn selectionFinish(self: *const Tracker, fallback: vt.Pin) vt.Pin {
    if (!self.right_prompt_active or self.right_prompt.garbage) {
        return fallback;
    }
    const right_prompt = self.right_prompt.*;
    if (right_prompt.x == 0 or
        !self.anchor.*.before(right_prompt) or
        !right_prompt.before(fallback) or
        terminal_ops.hashCells(right_prompt.cells(.right)) != self.right_prompt_hash)
    {
        return fallback;
    }
    return right_prompt.left(1);
}

fn finish(self: *Tracker, completion: TerminalCompletion, sink: anytype) void {
    const owned = self.command orelse {
        self.reset(.idle);
        return;
    };
    const command_len = terminal_ops.validPrefixLength(owned, osc.max_command_bytes);
    const duration = @max(@as(i64, 0), completion.clock.awake_ns - self.started_awake_ns);
    const output: []const u8 = if (self.output_tail) |tail| tail[0..self.output_len] else "";
    sink.emit(.{
        .bytes = owned[0..command_len],
        .cwd = self.command_cwd[0..self.command_cwd_len],
        .started_at_ms = self.started_at_ms,
        .duration_ns = duration,
        .exit_code = completion.exit_code,
        .status = completion.status,
        .truncated = self.command_truncated,
        .output = output,
        .output_truncated = self.output_observed > self.output_len,
        .output_observed = self.output_observed,
    });
    self.reset(.idle);
}

pub fn reset(self: *Tracker, phase: Phase) void {
    self.freeCommand();
    self.phase = phase;
    self.input.reset();
    self.anchor_erased = false;
    self.command_truncated = false;
    self.saw_foreground_child = false;
    self.output_len = 0;
    self.output_observed = 0;
}

/// Keeps the newest bytes of the running command's raw output in the
/// bounded tail: when full, the older half is discarded so the ending -
/// where errors usually are - survives.
pub fn captureOutput(self: *Tracker, bytes: []const u8) void {
    const tail = self.output_tail orelse return;
    self.output_observed +|= bytes.len;
    if (bytes.len >= tail.len) {
        @memcpy(tail, bytes[bytes.len - tail.len ..]);
        self.output_len = tail.len;
        return;
    }

    if (self.output_len + bytes.len > tail.len) {
        const keep = tail.len / 2;
        const drop = self.output_len - keep;
        std.mem.copyForwards(u8, tail[0..keep], tail[drop..self.output_len]);
        self.output_len = keep;
    }

    @memcpy(tail[self.output_len .. self.output_len + bytes.len], bytes);
    self.output_len += bytes.len;
}

fn freeCommand(self: *Tracker) void {
    if (self.command) |command| {
        self.gpa.free(command);
    }
    self.command = null;
}

const ExitObservation = struct {
    clock: Clock,
    exit_code: i32,
};

const TerminalCompletion = struct {
    clock: Clock,
    exit_code: ?i32,
    status: osc.Status,
};

const TerminalOutputObservation = struct {
    /// The emulator that has already replayed `bytes`.
    terminal: *vt.Terminal,
    bytes: []const u8,
    clock: Clock,
    shell_foreground: ?bool,
};
