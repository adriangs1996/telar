//! Shell-independent command capture from the PTY's rendered terminal state.

const std = @import("std");
const vt = @import("ghostty-vt");
const InputScanner = @import("InputScanner.zig");
const TerminalTracker = @import("TerminalTracker.zig");
const TerminalCollected = @import("TerminalCollected.zig");
const osc = @import("osc.zig");
const TypeAheadFixture = @import("TypeAheadFixture.zig");

pub const max_output_tail_bytes = 64 * 1024;

pub fn validPrefixLength(bytes: []const u8, limit: usize) usize {
    if (bytes.len <= limit) {
        return bytes.len;
    }
    var len = limit;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) : (len -= 1) {}
    return len;
}

pub fn rowIsBlank(pin: vt.Pin) bool {
    return cellsBlank(pin.cells(.all));
}

pub fn cellsBlank(cells: []const vt.Cell) bool {
    for (cells) |cell| {
        if (!cellBlank(cell)) {
            return false;
        }
    }
    return true;
}

pub fn cellBlank(cell: vt.Cell) bool {
    return !cell.hasText() or cell.codepoint() == ' ';
}

pub fn hashCells(cells: []const vt.Cell) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (cells) |cell| {
        hash ^= @as(u64, @bitCast(cell));
        hash *%= 0x100000001b3;
    }
    return hash;
}

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

test "captures the rendered line even when the edit cursor is not at its end" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 40, .rows = 8 });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ ");

    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal });
    defer tracker.deinit(&terminal);
    var collected: TerminalCollected = .{};
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

    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal });
    defer tracker.deinit(&terminal);
    var collected: TerminalCollected = .{};
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

    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal });
    defer tracker.deinit(&terminal);
    var collected: TerminalCollected = .{};
    _ = tracker.observeInput(.{
        .terminal = &terminal,
        .bytes = "huge\r",
        .shell_foreground = true,
        .clock = .{ .real_ms = 1, .awake_ns = 1 },
    }, &collected);

    // The echoed "command" is a paste far past the storable bound.
    const chunk = "x" ** 1024;
    for (0..(osc.max_command_bytes / 1024) + 32) |_| stream.nextSlice(chunk);
    stream.nextSlice("\r\n");
    try std.testing.expect(try tracker.captureSubmitted(&terminal));
    try std.testing.expect(tracker.command.?.len <= osc.max_command_bytes);
    try std.testing.expect(tracker.command_truncated);
}

test "Kitty graphics commands do not enter shell history" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 40, .rows = 8 });
    defer terminal.deinit(gpa);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("$ ");

    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal });
    defer tracker.deinit(&terminal);
    var collected: TerminalCollected = .{};
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

test "output capture keeps a bounded tail favoring the newest bytes" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);
    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal, .capture_output = true });
    defer tracker.deinit(&terminal);

    tracker.phase = .running;
    tracker.captureOutput("hello ");
    tracker.captureOutput("world");
    try std.testing.expectEqualStrings("hello world", tracker.output_tail.?[0..tracker.output_len]);
    try std.testing.expectEqual(@as(u64, 11), tracker.output_observed);

    const big = "x" ** (max_output_tail_bytes + 100);
    tracker.captureOutput(big);
    try std.testing.expectEqual(max_output_tail_bytes, tracker.output_len);
    try std.testing.expectEqual(@as(u64, 11 + big.len), tracker.output_observed);

    tracker.reset(.idle);
    try std.testing.expectEqual(@as(usize, 0), tracker.output_len);
    try std.testing.expectEqual(@as(u64, 0), tracker.output_observed);
}

test "output capture stays disabled without the opt-in" {
    const gpa = std.testing.allocator;
    var terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 20, .rows = 5 });
    defer terminal.deinit(gpa);
    var tracker = try TerminalTracker.init(gpa, .{ .cwd = "/work", .terminal = &terminal });
    defer tracker.deinit(&terminal);

    tracker.phase = .running;
    tracker.captureOutput("ignored");
    try std.testing.expect(tracker.output_tail == null);
    try std.testing.expectEqual(@as(u64, 0), tracker.output_observed);
}

test "type-ahead echoed by the kernel is re-anchored at the line editor's re-echo" {
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    for ("cd ~/.con") |byte| {
        fixture.typed(&.{byte});
        fixture.output(&.{byte});
    }
    fixture.output(TypeAheadFixture.startup);
    fixture.output(TypeAheadFixture.re_echo);
    for ("fig") |byte| {
        fixture.typed(&.{byte});
        fixture.output(&.{byte});
    }
    try fixture.submit();

    try std.testing.expectEqualStrings("cd ~/.config", fixture.command());
}

test "type-ahead is re-anchored when the prompt and the re-echo arrive together" {
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    for ("cd ~/.con") |byte| {
        fixture.typed(&.{byte});
        fixture.output(&.{byte});
    }
    fixture.output(TypeAheadFixture.startup ++ TypeAheadFixture.re_echo);
    for ("fig") |byte| {
        fixture.typed(&.{byte});
        fixture.output(&.{byte});
    }
    try fixture.submit();

    try std.testing.expectEqualStrings("cd ~/.config", fixture.command());
}

test "type-ahead with no echo is re-anchored once a prompt is painted" {
    // An instant prompt paints below the row where the first keystroke found
    // the cursor, and the typed text only appears after it.
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    fixture.typed("v");
    fixture.output("\r\n ~/sandbox/telar \r\n\u{276f} ");
    fixture.output("v");
    try fixture.submit();

    try std.testing.expectEqualStrings("v", fixture.command());
}

test "a clear-screen while editing is re-anchored at the repainted prompt" {
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    fixture.output("\r\n\r\n$ ");
    fixture.typed("ls");
    fixture.output("ls");
    fixture.typed("\x0c");
    fixture.output("\x1b[2J\x1b[H");
    fixture.output("$ ls");
    fixture.typed(" -la");
    fixture.output(" -la");
    try fixture.submit();

    try std.testing.expectEqualStrings("ls -la", fixture.command());
}

test "a prompt repainted below asynchronous output is re-anchored" {
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    fixture.output("$ ");
    fixture.typed("make");
    fixture.output("make");
    fixture.output("\r\n[1]  + done  sleep 5\r\n$ make");
    try fixture.submit();

    try std.testing.expectEqualStrings("make", fixture.command());
}

test "an erased anchor row without a repainted prompt captures nothing" {
    const gpa = std.testing.allocator;
    var fixture: TypeAheadFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    fixture.typed("x");
    fixture.output("\r\n\r\n");
    fixture.typed("\r");
    fixture.stream.nextSlice("\r\n");
    try std.testing.expect(!try fixture.tracker.captureSubmitted(&fixture.terminal));
    try std.testing.expectEqual(TerminalTracker.Phase.idle, fixture.tracker.phase);
}
