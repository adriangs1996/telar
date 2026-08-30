//! Shell-independent command capture from the PTY's rendered terminal state.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const escape = @import("escape.zig");
const osc = @import("osc.zig");

pub const max_command_bytes = osc.max_command_bytes;
pub const Clock = osc.Clock;
pub const Status = osc.Status;
pub const Command = osc.Command;

pub const InputObservation = struct {
    terminal: *vt.Terminal,
    bytes: []const u8,
    shell_foreground: bool,
    clock: Clock,
};

pub const OutputObservation = struct {
    bytes: []const u8,
    clock: Clock,
    shell_foreground: ?bool,
};

pub const ExitObservation = struct {
    clock: Clock,
    exit_code: i32,
};

const Completion = struct {
    clock: Clock,
    exit_code: ?i32,
    status: Status,
};

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    aux: osc.Tracker,
    anchor: *vt.Pin,
    right_prompt: *vt.Pin,
    right_prompt_active: bool = false,
    right_prompt_hash: u64 = 0,
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

    pub fn init(gpa: std.mem.Allocator, cwd: []const u8, terminal: *vt.Terminal) !Tracker {
        const screen = terminal.screens.active;
        const anchor = try screen.pages.trackPin(screen.cursor.page_pin.*);
        errdefer screen.pages.untrackPin(anchor);
        return .{
            .gpa = gpa,
            .aux = .init(cwd),
            // Allocate the tracked pin once. Starting an edit then only copies
            // the terminal cursor into it, so pane input remains allocation-free.
            .anchor = anchor,
            .right_prompt = try screen.pages.trackPin(screen.cursor.page_pin.*),
        };
    }

    pub fn deinit(tracker: *Tracker, terminal: *vt.Terminal) void {
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
    pub fn observeInput(tracker: *Tracker, observation: InputObservation, sink: anytype) usize {
        const terminal = observation.terminal;
        const bytes = observation.bytes;
        const shell_foreground = observation.shell_foreground;
        const clock = observation.clock;

        _ = tracker.aux.input(bytes);
        if (!shell_foreground or bytes.len == 0) return 0;

        // A new edit proves the previous command returned control to the shell.
        // Use its last PTY output as the end time so user think-time is excluded.
        if (tracker.phase == .running) {
            if (comptime builtin.mode == .Debug)
                tracker.next_input_completions += 1;
            var finished = clock;
            if (tracker.last_output_awake_ns >= tracker.started_awake_ns)
                finished.awake_ns = tracker.last_output_awake_ns;
            tracker.finish(.{ .clock = finished, .exit_code = null, .status = .completed }, sink);
        }
        if (tracker.phase == .awaiting_commit) return bytes.len;

        if (tracker.phase == .idle) tracker.beginEdit(terminal);
        const event = tracker.input.feed(bytes);
        if (event.cancelled) {
            tracker.reset(.idle);
            return bytes.len;
        }
        if (event.submitted and tracker.phase == .editing) {
            if (comptime builtin.mode == .Debug)
                tracker.submissions_armed += 1;
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
    pub fn commitBoundary(tracker: *const Tracker, bytes: []const u8) ?usize {
        if (tracker.phase != .awaiting_commit) return null;
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
    pub fn captureSubmitted(tracker: *Tracker, terminal: *vt.Terminal) !bool {
        if (tracker.phase != .awaiting_commit) return false;
        const screen = terminal.screens.active;
        const finish_pin = screen.cursor.page_pin.*;
        if (tracker.anchor.garbage or finish_pin.before(tracker.anchor.*)) {
            if (comptime builtin.mode == .Debug)
                tracker.capture_failures += 1;
            tracker.reset(.idle);
            return false;
        }

        const cols: usize = @max(1, terminal.cols);
        const max_rows = max_command_bytes / cols + 2;
        const clamped_finish = if (tracker.anchor.down(max_rows)) |limit| finish: {
            if (!limit.before(finish_pin)) break :finish finish_pin;
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
            if (comptime builtin.mode == .Debug)
                tracker.capture_failures += 1;
            tracker.gpa.free(text);
            tracker.reset(.idle);
            return false;
        }

        tracker.freeCommand();
        if (text.len > max_command_bytes) {
            const keep = validPrefixLength(text, max_command_bytes);
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
        if (comptime builtin.mode == .Debug)
            tracker.submissions_captured += 1;
        return true;
    }

    /// Observes one PTY output slice and completes commands from OSC markers or
    /// foreground-process transitions.
    ///
    /// ```zig
    /// tracker.observeOutput(.{ .bytes = bytes, .clock = clock, .shell_foreground = foreground }, &sink);
    /// ```
    pub fn observeOutput(tracker: *Tracker, observation: OutputObservation, sink: anytype) void {
        const bytes = observation.bytes;
        const clock = observation.clock;
        const shell_foreground = observation.shell_foreground;

        if (bytes.len != 0) tracker.last_output_awake_ns = clock.awake_ns;

        const Relay = struct {
            tracker: *Tracker,
            clock: Clock,
            sink: @TypeOf(sink),

            pub fn emit(relay: *@This(), value: osc.Command) void {
                if (relay.tracker.phase != .running) return;
                if (comptime builtin.mode == .Debug)
                    relay.tracker.auxiliary_completions += 1;
                relay.tracker.finish(.{
                    .clock = relay.clock,
                    .exit_code = value.exit_code,
                    .status = value.status,
                }, relay.sink);
            }
        };
        var relay: Relay = .{ .tracker = tracker, .clock = clock, .sink = sink };
        tracker.aux.feed(.{ .bytes = bytes, .clock = clock }, &relay);

        if (tracker.phase != .running) return;
        if (shell_foreground) |is_shell| {
            if (!is_shell) {
                tracker.saw_foreground_child = true;
            } else if (tracker.saw_foreground_child) {
                if (comptime builtin.mode == .Debug)
                    tracker.foreground_completions += 1;
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
        if (tracker.phase == .running)
            tracker.finish(.{ .clock = observation.clock, .exit_code = observation.exit_code, .status = .completed }, sink)
        else
            tracker.reset(.idle);
    }

    /// Completes a running command as interrupted, or clears an incomplete edit.
    ///
    /// ```zig
    /// tracker.interrupt(clock, &sink);
    /// ```
    pub fn interrupt(tracker: *Tracker, clock: Clock, sink: anytype) void {
        if (tracker.phase == .running)
            tracker.finish(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink)
        else
            tracker.reset(.idle);
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
            tracker.right_prompt_hash = hashCells(tracker.right_prompt.*.cells(.right));
            tracker.right_prompt_active = true;
            return;
        }
    }

    fn selectionFinish(tracker: *const Tracker, fallback: vt.Pin) vt.Pin {
        if (!tracker.right_prompt_active or tracker.right_prompt.garbage) return fallback;
        const right_prompt = tracker.right_prompt.*;
        if (right_prompt.x == 0 or
            !tracker.anchor.*.before(right_prompt) or
            !right_prompt.before(fallback) or
            hashCells(right_prompt.cells(.right)) != tracker.right_prompt_hash)
        {
            return fallback;
        }
        return right_prompt.left(1);
    }

    fn finish(tracker: *Tracker, completion: Completion, sink: anytype) void {
        const owned = tracker.command orelse {
            tracker.reset(.idle);
            return;
        };
        const command_len = validPrefixLength(owned, max_command_bytes);
        const duration = @max(@as(i64, 0), completion.clock.awake_ns - tracker.started_awake_ns);
        sink.emit(.{
            .bytes = owned[0..command_len],
            .cwd = tracker.command_cwd[0..tracker.command_cwd_len],
            .started_at_ms = tracker.started_at_ms,
            .duration_ns = duration,
            .exit_code = completion.exit_code,
            .status = completion.status,
            .truncated = tracker.command_truncated,
        });
        tracker.reset(.idle);
    }

    fn reset(tracker: *Tracker, phase: Phase) void {
        tracker.freeCommand();
        tracker.phase = phase;
        tracker.input.reset();
        tracker.command_truncated = false;
        tracker.saw_foreground_child = false;
    }

    fn freeCommand(tracker: *Tracker) void {
        if (tracker.command) |command| tracker.gpa.free(command);
        tracker.command = null;
    }
};

fn validPrefixLength(bytes: []const u8, limit: usize) usize {
    if (bytes.len <= limit) return bytes.len;
    var len = limit;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) : (len -= 1) {}
    return len;
}

fn hashCells(cells: []const vt.Cell) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (cells) |cell| {
        hash ^= @as(u64, @bitCast(cell));
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub const InputScanner = escape.InputScanner;

test "bracketed paste newlines do not submit" {
    var scanner: InputScanner = .{};
    try std.testing.expect(!scanner.feed("\x1b[200~echo one\necho two").submitted);
    try std.testing.expect(scanner.feed("\x1b[201~\r").submitted);
}

test "bracketed paste markers survive chunk boundaries" {
    var scanner: InputScanner = .{};
    try std.testing.expect(!scanner.feed("\x1b[20").submitted);
    try std.testing.expect(!scanner.feed("0~a\nb\x1b[2").submitted);
    try std.testing.expect(!scanner.feed("01~").submitted);
    try std.testing.expect(scanner.feed("\n").submitted);
}

test "control-c cancels an edit" {
    var scanner: InputScanner = .{};
    try std.testing.expect(scanner.feed("partial\x03").cancelled);
}

test "UTF-8 truncation stops on a codepoint boundary" {
    const bytes = "aaaaé";
    try std.testing.expectEqual(@as(usize, 4), validPrefixLength(bytes, 5));
}

const Collected = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    cwd: [256]u8 = undefined,
    cwd_len: usize = 0,
    exit_code: ?i32 = null,

    pub fn emit(collected: *Collected, command: Command) void {
        collected.len = @min(command.bytes.len, collected.bytes.len);
        @memcpy(collected.bytes[0..collected.len], command.bytes[0..collected.len]);
        collected.cwd_len = @min(command.cwd.len, collected.cwd.len);
        @memcpy(collected.cwd[0..collected.cwd_len], command.cwd[0..collected.cwd_len]);
        collected.exit_code = command.exit_code;
    }
};

test "captures the rendered line even when the edit cursor is not at its end" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 40, .rows = 8 });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ ");

    var tracker = try Tracker.init(gpa, "/work", &terminal);
    defer tracker.deinit(&terminal);
    var collected: Collected = .{};
    _ = tracker.observeInput(.{
        .terminal = &terminal,
        .bytes = "edited with arrows\r",
        .shell_foreground = true,
        .clock = .{ .real_ms = 10, .awake_ns = 100 },
    }, &collected);
    tracker.updateCwd("/after-submission");

    const output = "echo persisted\x1b[5D\r\n";
    try std.testing.expectEqual(output.len, tracker.commitBoundary(output).?);
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(.{
        .clock = .{ .real_ms = 20, .awake_ns = 500 },
        .exit_code = 7,
    }, &collected);

    try std.testing.expectEqualStrings("echo persisted", collected.bytes[0..collected.len]);
    try std.testing.expectEqualStrings("/work", collected.cwd[0..collected.cwd_len]);
    try std.testing.expectEqual(@as(?i32, 7), collected.exit_code);
}

test "excludes an unchanged right prompt from the submitted command" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 40, .rows = 8 });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ \x1b[30GSTATUS\x1b[3G");

    var tracker = try Tracker.init(gpa, "/work", &terminal);
    defer tracker.deinit(&terminal);
    var collected: Collected = .{};
    _ = tracker.observeInput(.{
        .terminal = &terminal,
        .bytes = "echo ok\r",
        .shell_foreground = true,
        .clock = .{ .real_ms = 10, .awake_ns = 100 },
    }, &collected);

    const output = "echo ok\r\n";
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(.{
        .clock = .{ .real_ms = 20, .awake_ns = 500 },
        .exit_code = 0,
    }, &collected);

    try std.testing.expectEqualStrings("echo ok", collected.bytes[0..collected.len]);
}

test "a captured command is bounded in bytes while resident" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{
        .cols = 80,
        .rows = 24,
        // Enough scrollback that the tracked anchor survives the paste; the
        // bound under test is the tracker's, not the emulator's.
        .max_scrollback_bytes = 4 * 1024 * 1024,
    });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ ");

    var tracker = try Tracker.init(gpa, "/work", &terminal);
    defer tracker.deinit(&terminal);
    var collected: Collected = .{};
    _ = tracker.observeInput(.{
        .terminal = &terminal,
        .bytes = "huge\r",
        .shell_foreground = true,
        .clock = .{ .real_ms = 1, .awake_ns = 1 },
    }, &collected);

    // The echoed "command" is a paste far past the storable bound.
    const chunk = "x" ** 1024;
    for (0..(max_command_bytes / 1024) + 32) |_| stream.nextSlice(chunk);
    stream.nextSlice("\r\n");
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    try std.testing.expect(tracker.command.?.len <= max_command_bytes);
    try std.testing.expect(tracker.command_truncated);
}

test "Kitty graphics commands do not enter shell history" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 40, .rows = 8 });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ ");

    var tracker = try Tracker.init(gpa, "/work", &terminal);
    defer tracker.deinit(&terminal);
    var collected: Collected = .{};
    _ = tracker.observeInput(.{
        .terminal = &terminal,
        .bytes = "echo safe\r",
        .shell_foreground = true,
        .clock = .{ .real_ms = 10, .awake_ns = 100 },
    }, &collected);
    const output = "echo safe\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\r\n";
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(.{
        .clock = .{ .real_ms = 20, .awake_ns = 500 },
        .exit_code = 0,
    }, &collected);
    try std.testing.expectEqualStrings("echo safe", collected.bytes[0..collected.len]);
}
