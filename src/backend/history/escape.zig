//! Escape-sequence scanners shared by the backend.
//!
//! Three small byte-at-a-time automata live here so their subtle rules -
//! what terminates a string, what a stray ESC means, which C1 bytes are
//! real controls - are decided once, tested once, and preserved across
//! arbitrary read boundaries as the parser invariants require.
//!
//! None of these is the emulator: ghostty alone defines what a screen is.
//! These recognizers only frame byte streams for accounting (KGP chunk
//! counting), history capture (OSC payloads), and input classification
//! (submits and bracketed paste).

const std = @import("std");

pub const esc = 0x1b;
pub const bel = 0x07;

pub const OscScanner = @import("OscScanner.zig");

pub const KittyFramingCounter = @import("KittyFramingCounter.zig");

pub const InputScanner = @import("InputScanner.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const OscCapture = @import("OscCapture.zig");

fn collectOsc(scanner: *OscScanner, bytes: []const u8, capture: OscCapture) void {
    for (bytes) |byte| switch (scanner.next(byte)) {
        .none, .start => {},
        .byte => |value| capture.payloads.appendAssumeCapacity(value),
        .end => capture.ends.* += 1,
    };
}

test "the input scanner tracks plain typed text with backspaces applied" {
    var scanner: InputScanner = .{};
    _ = scanner.feed("cd ~/.cox\x7fn");
    try std.testing.expectEqualStrings("cd ~/.con", scanner.typedText().?);

    _ = scanner.feed("\x1b[D");
    try std.testing.expect(scanner.typedText() == null);

    scanner.reset();
    _ = scanner.feed("ok\x15");
    try std.testing.expect(scanner.typedText() == null);

    scanner.reset();
    _ = scanner.feed("caf\xc3\xa9");
    try std.testing.expect(scanner.typedText() == null);
}

test "the OSC scanner produces identical events for any byte split" {
    const gpa = std.testing.allocator;
    const stream = "before\x1b]133;A\x07between\x1b]7;file://h/p\x1b\\\x1b]x\x1by\x1b]2;t\x07";

    var whole_payloads = try std.ArrayList(u8).initCapacity(gpa, stream.len);
    defer whole_payloads.deinit(gpa);
    var whole_ends: usize = 0;
    var whole: OscScanner = .{};
    collectOsc(&whole, stream, .{ .payloads = &whole_payloads, .ends = &whole_ends });
    // "x" streams out before its sequence is abandoned; the consumer resets
    // its buffer on the next `.start`, the scanner just reports bytes.
    try std.testing.expectEqualStrings("133;A7;file://h/px2;t", whole_payloads.items);
    try std.testing.expectEqual(@as(usize, 3), whole_ends);

    for (1..stream.len) |split| {
        var payloads = try std.ArrayList(u8).initCapacity(gpa, stream.len);
        defer payloads.deinit(gpa);
        var ends: usize = 0;
        var scanner: OscScanner = .{};
        collectOsc(&scanner, stream[0..split], .{ .payloads = &payloads, .ends = &ends });
        collectOsc(&scanner, stream[split..], .{ .payloads = &payloads, .ends = &ends });
        try std.testing.expectEqualStrings(whole_payloads.items, payloads.items);
        try std.testing.expectEqual(whole_ends, ends);
    }
}

test "the Kitty framing counter counts identically for any byte split" {
    const stream = "text\x1b_Gm=1;AAAA\x1b\\ß\x1b_Xnope\x1b\\\x1b_Gm=0;BB\x1b\\";
    var whole: KittyFramingCounter = .{};
    try std.testing.expectEqual(@as(usize, 2), whole.observe(stream));

    for (1..stream.len) |split| {
        var counter: KittyFramingCounter = .{};
        var complete = counter.observe(stream[0..split]);
        complete += counter.observe(stream[split..]);
        try std.testing.expectEqual(@as(usize, 2), complete);
    }
}

test "the input scanner classifies identically for any byte split" {
    const stream = "abc\x1b[200~in\npaste\x1b[201~\r";
    var whole: InputScanner = .{};
    const whole_event = whole.feed(stream);
    try std.testing.expect(whole_event.submitted);
    try std.testing.expect(!whole_event.cancelled);

    for (1..stream.len) |split| {
        var scanner: InputScanner = .{};
        const first = scanner.feed(stream[0..split]);
        const second = scanner.feed(stream[split..]);
        // The newline inside the paste must never submit; the final '\r'
        // always lands in the second chunk.
        try std.testing.expect(!first.submitted);
        try std.testing.expect(second.submitted);
        try std.testing.expect(!first.cancelled and !second.cancelled);
    }
}

test "Kitty framing counter survives splits and ignores other APCs" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expectEqual(@as(usize, 0), counter.observe("text\x1b_Gm=1;AA"));
    try std.testing.expectEqual(@as(usize, 1), counter.observe("AA\x1b\\"));
    try std.testing.expectEqual(@as(usize, 0), counter.observe("\x1b_Xnot-kitty\x1b\\"));
    try std.testing.expectEqual(@as(usize, 2), counter.observe(
        "\x1b_Gm=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\",
    ));
}

test "UTF-8 continuation bytes do not desynchronize the Kitty framing counter" {
    // 0x9f is the C1 APC introducer, but the emulator parses the stream as
    // UTF-8, where 0x9f is an ordinary continuation byte ("ß" is 0xC3 0x9F).
    // Treating it as an APC start swallows the following real command.
    var counter: KittyFramingCounter = .{};
    try std.testing.expectEqual(@as(usize, 0), counter.observe("ß"));
    try std.testing.expectEqual(@as(usize, 1), counter.observe("\x1b_Gm=1;AA\x1b\\"));
}
