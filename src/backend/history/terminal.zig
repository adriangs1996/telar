//! Shell-independent command capture from the PTY's rendered terminal state.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const osc = @import("osc.zig");

pub const max_command_bytes = osc.max_command_bytes;
pub const Clock = osc.Clock;
pub const Status = osc.Status;
pub const Command = osc.Command;

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

    pub fn init(
        gpa: std.mem.Allocator,
        cwd: []const u8,
        terminal: *vt.Terminal,
    ) !Tracker {
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

    pub fn observeInput(
        tracker: *Tracker,
        terminal: *vt.Terminal,
        bytes: []const u8,
        shell_foreground: bool,
        clock: Clock,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), Command) void,
    ) usize {
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
            tracker.finish(finished, null, .completed, context, on_command);
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

        const selection_finish = tracker.selectionFinish(finish_pin);
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
        tracker.command = text;
        tracker.command_truncated = text.len > max_command_bytes;
        tracker.phase = .running;
        if (comptime builtin.mode == .Debug)
            tracker.submissions_captured += 1;
        return true;
    }

    pub fn observeOutput(
        tracker: *Tracker,
        bytes: []const u8,
        clock: Clock,
        shell_foreground: ?bool,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), Command) void,
    ) void {
        if (bytes.len != 0) tracker.last_output_awake_ns = clock.awake_ns;

        const Relay = struct {
            tracker: *Tracker,
            clock: Clock,
            context: @TypeOf(context),

            fn command(relay: *@This(), value: osc.Command) void {
                if (relay.tracker.phase != .running) return;
                if (comptime builtin.mode == .Debug)
                    relay.tracker.auxiliary_completions += 1;
                relay.tracker.finish(
                    relay.clock,
                    value.exit_code,
                    value.status,
                    relay.context,
                    on_command,
                );
            }
        };
        var relay: Relay = .{ .tracker = tracker, .clock = clock, .context = context };
        tracker.aux.feed(bytes, clock, &relay, Relay.command);

        if (tracker.phase != .running) return;
        if (shell_foreground) |is_shell| {
            if (!is_shell) {
                tracker.saw_foreground_child = true;
            } else if (tracker.saw_foreground_child) {
                if (comptime builtin.mode == .Debug)
                    tracker.foreground_completions += 1;
                tracker.finish(clock, null, .completed, context, on_command);
            }
        }
    }

    pub fn shellExited(
        tracker: *Tracker,
        clock: Clock,
        exit_code: i32,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), Command) void,
    ) void {
        if (tracker.phase == .running)
            tracker.finish(clock, exit_code, .completed, context, on_command)
        else
            tracker.reset(.idle);
    }

    pub fn interrupt(
        tracker: *Tracker,
        clock: Clock,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), Command) void,
    ) void {
        if (tracker.phase == .running)
            tracker.finish(clock, null, .interrupted, context, on_command)
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

    fn finish(
        tracker: *Tracker,
        clock: Clock,
        exit_code: ?i32,
        status: Status,
        context: anytype,
        comptime on_command: fn (@TypeOf(context), Command) void,
    ) void {
        const owned = tracker.command orelse {
            tracker.reset(.idle);
            return;
        };
        const command_len = validPrefixLength(owned, max_command_bytes);
        const duration = @max(@as(i64, 0), clock.awake_ns - tracker.started_awake_ns);
        on_command(context, .{
            .bytes = owned[0..command_len],
            .cwd = tracker.command_cwd[0..tracker.command_cwd_len],
            .started_at_ms = tracker.started_at_ms,
            .duration_ns = duration,
            .exit_code = exit_code,
            .status = status,
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

pub const InputScanner = struct {
    state: State = .ground,
    parameter: u16 = 0,
    has_parameter: bool = false,

    const State = enum { ground, escape, csi, paste, paste_escape, paste_csi };
    pub const Event = struct { submitted: bool = false, cancelled: bool = false };

    pub fn reset(scanner: *InputScanner) void {
        scanner.* = .{};
    }

    pub fn feed(scanner: *InputScanner, bytes: []const u8) Event {
        var event: Event = .{};
        for (bytes) |byte| scanner.feedByte(byte, &event);
        return event;
    }

    fn feedByte(scanner: *InputScanner, byte: u8, event: *Event) void {
        switch (scanner.state) {
            .ground => switch (byte) {
                0x1b => scanner.state = .escape,
                '\r', '\n' => event.submitted = true,
                0x03 => event.cancelled = true,
                else => {},
            },
            .escape => if (byte == '[') {
                scanner.startCsi(.csi);
            } else {
                scanner.state = .ground;
            },
            .csi => scanner.csiByte(byte, false),
            .paste => {
                if (byte == 0x1b) scanner.state = .paste_escape;
            },
            .paste_escape => if (byte == '[') {
                scanner.startCsi(.paste_csi);
            } else {
                scanner.state = .paste;
            },
            .paste_csi => scanner.csiByte(byte, true),
        }
    }

    fn startCsi(scanner: *InputScanner, state: State) void {
        scanner.state = state;
        scanner.parameter = 0;
        scanner.has_parameter = false;
    }

    fn csiByte(scanner: *InputScanner, byte: u8, from_paste: bool) void {
        if (byte >= '0' and byte <= '9') {
            scanner.has_parameter = true;
            scanner.parameter = std.math.mul(u16, scanner.parameter, 10) catch std.math.maxInt(u16);
            scanner.parameter = std.math.add(u16, scanner.parameter, byte - '0') catch std.math.maxInt(u16);
            return;
        }
        if (byte == '~' and scanner.has_parameter) {
            if (!from_paste and scanner.parameter == 200) {
                scanner.state = .paste;
                return;
            }
            if (from_paste and scanner.parameter == 201) {
                scanner.state = .ground;
                return;
            }
        }
        scanner.state = if (from_paste) .paste else .ground;
    }
};

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

    fn collect(collected: *Collected, command: Command) void {
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
    _ = tracker.observeInput(
        &terminal,
        "edited with arrows\r",
        true,
        .{ .real_ms = 10, .awake_ns = 100 },
        &collected,
        Collected.collect,
    );
    tracker.updateCwd("/after-submission");

    const output = "echo persisted\x1b[5D\r\n";
    try std.testing.expectEqual(output.len, tracker.commitBoundary(output).?);
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(
        .{ .real_ms = 20, .awake_ns = 500 },
        7,
        &collected,
        Collected.collect,
    );

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
    _ = tracker.observeInput(
        &terminal,
        "echo ok\r",
        true,
        .{ .real_ms = 10, .awake_ns = 100 },
        &collected,
        Collected.collect,
    );

    const output = "echo ok\r\n";
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(
        .{ .real_ms = 20, .awake_ns = 500 },
        0,
        &collected,
        Collected.collect,
    );

    try std.testing.expectEqualStrings("echo ok", collected.bytes[0..collected.len]);
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
    _ = tracker.observeInput(
        &terminal,
        "echo safe\r",
        true,
        .{ .real_ms = 10, .awake_ns = 100 },
        &collected,
        Collected.collect,
    );
    const output = "echo safe\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\r\n";
    stream.nextSlice(output);
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    tracker.shellExited(
        .{ .real_ms = 20, .awake_ns = 500 },
        0,
        &collected,
        Collected.collect,
    );
    try std.testing.expectEqualStrings("echo safe", collected.bytes[0..collected.len]);
}
