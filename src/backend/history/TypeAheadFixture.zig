const vt = @import("ghostty-vt");
const TerminalTracker = @import("TerminalTracker.zig");
const TerminalCollected = @import("TerminalCollected.zig");
const ClockType = @import("Clock.zig");
const std = @import("std");
/// The observer replays output into the emulator before the tracker sees it.
const TypeAheadFixture = @This();

terminal: vt.Terminal,
stream: vt.TerminalStream,
tracker: TerminalTracker,
collected: TerminalCollected = .{},
clock: ClockType = .{ .real_ms = 1, .awake_ns = 1 },

// Recorded from zsh with powerlevel10k on an 80 column pty, reduced to the
// bytes that move the cursor or paint text. The shell finds the kernel
// echo mid row, prints its end-of-output marker, clears from the next row,
// paints a two line prompt with a right prompt and lets the line editor
// re-echo the pending input.
pub const startup =
    "\x1b[1m\x1b[7m%\x1b[27m\x1b[1m\x1b[0m" ++ " " ** 79 ++ "\r \r" ++
    "\x1b]2;title\x07\r\x1b[0m\x1b[27m\x1b[24m\x1b[J\r\n" ++
    " ~/sandbox/telar  main !? \r\n" ++
    "\u{276f} \x1b[K\x1b[61C[ +544 ][ -348 ]\x1b[77D\x1b[6 q\x1b[?2004h";
pub const re_echo = "c\x08cd ~/.con";

pub fn init(fixture: *TypeAheadFixture, gpa: std.mem.Allocator) !void {
    fixture.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 24 });
    errdefer fixture.terminal.deinit(gpa);
    fixture.stream = fixture.terminal.vtStream();
    errdefer fixture.stream.deinit();
    fixture.tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &fixture.terminal });
    fixture.collected = .{};
    fixture.clock = .{ .real_ms = 1, .awake_ns = 1 };
}

pub fn deinit(fixture: *TypeAheadFixture, gpa: std.mem.Allocator) void {
    fixture.tracker.deinit(&fixture.terminal);
    fixture.stream.deinit();
    fixture.terminal.deinit(gpa);
}

pub fn typed(fixture: *TypeAheadFixture, bytes: []const u8) void {
    fixture.clock.awake_ns += 1;
    _ = fixture.tracker.observeInput(.{
        .terminal = &fixture.terminal,
        .bytes = bytes,
        .shell_foreground = true,
        .clock = fixture.clock,
    }, &fixture.collected);
}

pub fn output(fixture: *TypeAheadFixture, bytes: []const u8) void {
    fixture.clock.awake_ns += 1;
    fixture.stream.nextSlice(bytes);
    fixture.tracker.observeOutput(.{
        .terminal = &fixture.terminal,
        .bytes = bytes,
        .clock = fixture.clock,
        .shell_foreground = true,
    }, &fixture.collected);
}

pub fn submit(fixture: *TypeAheadFixture) !void {
    fixture.typed("\r");
    const committed = "\r\r\n";
    fixture.stream.nextSlice(committed);
    try std.testing.expect(try fixture.tracker.captureSubmitted(&fixture.terminal));
    fixture.tracker.shellExited(.{ .clock = fixture.clock, .exit_code = 0 }, &fixture.collected);
}

pub fn command(fixture: *const TypeAheadFixture) []const u8 {
    return fixture.collected.bytes[0..fixture.collected.len];
}
