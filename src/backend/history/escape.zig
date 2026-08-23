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

/// Frames `ESC ]` OSC sequences and streams their payload as events.
///
/// Raw C1 introducers are deliberately not honoured: the emulator parses the
/// stream as UTF-8, where 0x9d and 0x9c are continuation bytes.
pub const OscScanner = struct {
    state: State = .ground,

    const State = enum { ground, escape, osc, osc_escape };

    pub const Event = union(enum) {
        /// Byte is not part of an OSC sequence.
        none,
        /// `ESC ]` seen; a payload follows.
        start,
        /// One payload byte.
        byte: u8,
        /// The sequence terminated (BEL or ST).
        end,
    };

    pub fn next(scanner: *OscScanner, input: u8) Event {
        switch (scanner.state) {
            .ground => {
                if (input == esc) scanner.state = .escape;
                return .none;
            },
            .escape => {
                if (input == ']') {
                    scanner.state = .osc;
                    return .start;
                }
                scanner.state = .ground;
                return .none;
            },
            .osc => switch (input) {
                bel => {
                    scanner.state = .ground;
                    return .end;
                },
                esc => {
                    scanner.state = .osc_escape;
                    return .none;
                },
                else => return .{ .byte = input },
            },
            .osc_escape => {
                if (input == '\\') {
                    scanner.state = .ground;
                    return .end;
                }
                // An ESC that was not a terminator abandons the sequence.
                // A second ESC may still open a fresh escape.
                scanner.state = if (input == esc) .escape else .ground;
                return .none;
            },
        }
    }
};

/// Counts complete Kitty APC commands across arbitrary PTY read boundaries
/// without retaining their payload. Ghostty performs the actual parsing; this
/// recognizer exists only to enforce a bounded number of chunks in an
/// incomplete upload.
///
/// Only ESC-introduced sequences count. The emulator parses the stream as
/// UTF-8, where the raw C1 bytes 0x9f (APC) and 0x9c (ST) are ordinary
/// continuation bytes; honouring them here would let plain text ("ß" is
/// 0xC3 0x9F) desynchronize the chunk count.
pub const KittyFramingCounter = struct {
    state: State = .normal,

    const State = enum { normal, escape, apc_identify, kitty, kitty_escape, other, other_escape };

    pub fn observe(counter: *KittyFramingCounter, bytes: []const u8) usize {
        var complete: usize = 0;
        for (bytes) |byte| switch (counter.state) {
            .normal => counter.state = if (byte == esc) .escape else .normal,
            .escape => counter.state = switch (byte) {
                '_' => .apc_identify,
                esc => .escape,
                else => .normal,
            },
            .apc_identify => counter.state = if (byte == 'G')
                .kitty
            else if (byte == esc)
                .other_escape
            else
                .other,
            .kitty => counter.state = switch (byte) {
                esc => .kitty_escape,
                else => .kitty,
            },
            .kitty_escape => counter.state = if (byte == '\\') state: {
                complete += 1;
                break :state .normal;
            } else if (byte == esc)
                .kitty_escape
            else
                .kitty,
            .other => counter.state = switch (byte) {
                esc => .other_escape,
                else => .other,
            },
            .other_escape => counter.state = if (byte == '\\')
                .normal
            else if (byte == esc)
                .other_escape
            else
                .other,
        };
        return complete;
    }
};

/// Classifies keyboard bytes going *to* a child: submits, cancels, and
/// bracketed paste. Bracketed paste identifies paste; newlines inside a paste
/// are content, never a submit - the invariant that timing heuristics must
/// not decide what a paste is.
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
                esc => scanner.state = .escape,
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
                if (byte == esc) scanner.state = .paste_escape;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn collectOsc(scanner: *OscScanner, bytes: []const u8, payloads: *std.ArrayList(u8), ends: *usize) void {
    for (bytes) |byte| switch (scanner.next(byte)) {
        .none, .start => {},
        .byte => |value| payloads.appendAssumeCapacity(value),
        .end => ends.* += 1,
    };
}

test "the OSC scanner produces identical events for any byte split" {
    const gpa = std.testing.allocator;
    const stream = "before\x1b]133;A\x07between\x1b]7;file://h/p\x1b\\\x1b]x\x1by\x1b]2;t\x07";

    var whole_payloads = try std.ArrayList(u8).initCapacity(gpa, stream.len);
    defer whole_payloads.deinit(gpa);
    var whole_ends: usize = 0;
    var whole: OscScanner = .{};
    collectOsc(&whole, stream, &whole_payloads, &whole_ends);
    // "x" streams out before its sequence is abandoned; the consumer resets
    // its buffer on the next `.start`, the scanner just reports bytes.
    try std.testing.expectEqualStrings("133;A7;file://h/px2;t", whole_payloads.items);
    try std.testing.expectEqual(@as(usize, 3), whole_ends);

    for (1..stream.len) |split| {
        var payloads = try std.ArrayList(u8).initCapacity(gpa, stream.len);
        defer payloads.deinit(gpa);
        var ends: usize = 0;
        var scanner: OscScanner = .{};
        collectOsc(&scanner, stream[0..split], &payloads, &ends);
        collectOsc(&scanner, stream[split..], &payloads, &ends);
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
