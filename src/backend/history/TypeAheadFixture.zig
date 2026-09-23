const vt = @import("ghostty-vt");
const TerminalTracker = @import("TerminalTracker.zig");
const TerminalCollected = @import("TerminalCollected.zig");
const Clock = @import("Clock.zig");
const std = @import("std");
/// The observer replays output into the emulator before the tracker sees it.
const TypeAheadFixture = @This();

terminal: vt.Terminal,
stream: vt.TerminalStream,
tracker: TerminalTracker,
collected: TerminalCollected = .{},
clock: Clock = .{ .real_ms = 1, .awake_ns = 1 },

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

pub fn init(self: *TypeAheadFixture, gpa: std.mem.Allocator) !void {
    self.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 24 });
    errdefer self.terminal.deinit(gpa);
    self.stream = self.terminal.vtStream();
    errdefer self.stream.deinit();
    self.tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &self.terminal });
    self.collected = .{};
    self.clock = .{ .real_ms = 1, .awake_ns = 1 };
}

pub fn deinit(self: *TypeAheadFixture, gpa: std.mem.Allocator) void {
    self.tracker.deinit(&self.terminal);
    self.stream.deinit();
    self.terminal.deinit(gpa);
}

pub fn typed(self: *TypeAheadFixture, bytes: []const u8) void {
    self.clock.awake_ns += 1;
    _ = self.tracker.observeInput(.{
        .terminal = &self.terminal,
        .bytes = bytes,
        .shell_foreground = true,
        .clock = self.clock,
    }, &self.collected);
}

pub fn output(self: *TypeAheadFixture, bytes: []const u8) void {
    self.clock.awake_ns += 1;
    self.stream.nextSlice(bytes);
    self.tracker.observeOutput(.{
        .terminal = &self.terminal,
        .bytes = bytes,
        .clock = self.clock,
        .shell_foreground = true,
    }, &self.collected);
}

pub fn submit(self: *TypeAheadFixture) !void {
    self.typed("\r");
    const committed = "\r\r\n";
    self.stream.nextSlice(committed);
    try std.testing.expect(try self.tracker.captureSubmitted(&self.terminal));
    self.tracker.shellExited(.{ .clock = self.clock, .exit_code = 0 }, &self.collected);
}

pub fn command(self: *const TypeAheadFixture) []const u8 {
    return self.collected.bytes[0..self.collected.len];
}
