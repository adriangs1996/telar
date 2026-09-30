//! Where APC strings, and the Kitty graphics commands among them, begin and
//! end in a PTY stream split at arbitrary read boundaries, exactly as the
//! pinned Ghostty parser frames them (`parse_table.zig`, `stream.zig`):
//!
//! - ESC followed by `X`, `^` or `_` opens an APC string (SOS, PM and APC
//!   share one state), and so does ESC followed by the raw C1 bytes 0x98,
//!   0x9E or 0x9F. A first content byte `G` makes it a Kitty command.
//! - The string ends at ESC, which also starts the next escape sequence, at
//!   ST (0x9C), at CAN or SUB, and at the C1 bytes 0x80-0x97 and 0x99-0x9D.
//!   Ghostty runs the Kitty command whichever ended it.
//! - 0x98, 0x9E, 0x9F and 0xA0-0xFF inside the string are ignored: they
//!   neither end it nor belong to its content.
//! - Outside a string Ghostty decodes UTF-8, so raw C1 bytes there are
//!   continuation bytes, not introducers ("ß" is 0xC3 0x9F).
//!
//! Runs of bytes that cannot change the state are skipped with vector
//! searches. Nothing allocates.
const std = @import("std");
const ApcTransition = @import("ApcTransition.zig").ApcTransition;
const ApcFraming = @This();

const esc = 0x1b;
const can = 0x18;
const sub = 0x1a;
const first_c1 = 0x80;
const kitty_identifier = 'G';
const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
const Bytes = @Vector(vector_len, u8);

state: State = .ground,

const State = enum { ground, escape, identify, kitty, other };

/// Whether the last byte observed left the framing inside a Kitty command.
/// Example: `if (framing.inKitty()) hold();`.
pub fn inKitty(self: *const ApcFraming) bool {
    return self.state == .kitty;
}

/// Advances from `index.*` to just past the next byte that starts or ends a
/// Kitty command and reports which, or to the end of `bytes` and returns
/// null. The state carries across calls, so a command may span reads.
///
/// ```zig
/// var index: usize = 0;
/// while (framing.advance(bytes, &index)) |transition| handle(transition, index);
/// ```
pub fn advance(self: *ApcFraming, bytes: []const u8, index: *usize) ?ApcTransition {
    var at = index.*;
    defer index.* = at;
    while (at < bytes.len) {
        switch (self.state) {
            .ground => {
                at = findIntroducer(bytes, at) orelse {
                    self.state = if (bytes[bytes.len - 1] == esc) .escape else .ground;
                    at = bytes.len;
                    return null;
                };
                self.state = .identify;
                continue;
            },
            .kitty, .other => {
                at = findBreak(bytes, at);
                if (at == bytes.len) {
                    return null;
                }
            },
            .escape, .identify => {},
        }

        const byte = bytes[at];
        at += 1;
        if (self.step(byte)) |transition| {
            return transition;
        }
    }

    return null;
}

/// Whether `byte` inside an APC string is part of its content: C0 other
/// than CAN, SUB and ESC, and printable ASCII.
/// Example: `if (ApcFraming.isContent(byte)) keep(byte);`.
pub fn isContent(byte: u8) bool {
    return byte < first_c1 and byte != can and byte != sub and byte != esc;
}

fn step(self: *ApcFraming, byte: u8) ?ApcTransition {
    switch (self.state) {
        .ground => {
            if (byte == esc) {
                self.state = .escape;
            }
        },
        .escape => self.state = if (opensString(byte)) .identify else if (byte == esc) .escape else .ground,
        .identify => {
            if (byte == kitty_identifier) {
                self.state = .kitty;
                return .kitty_started;
            }

            if (endsString(byte)) {
                self.state = after(byte);
            } else if (isContent(byte)) {
                self.state = .other;
            }
        },
        .kitty => {
            if (endsString(byte)) {
                self.state = after(byte);
                return .kitty_ended;
            }
        },
        .other => {
            if (endsString(byte)) {
                self.state = after(byte);
            }
        },
    }

    return null;
}

// After ESC: X, ^ and _ open SOS, PM and APC; the raw C1 introducers do too.
fn opensString(byte: u8) bool {
    return switch (byte) {
        'X', '^', '_', 0x98, 0x9e, 0x9f => true,
        else => false,
    };
}

fn endsString(byte: u8) bool {
    return switch (byte) {
        can, sub, esc, 0x80...0x97, 0x99...0x9d => true,
        else => false,
    };
}

// ESC ends the string and starts an escape sequence; every other end
// returns to ground as far as strings are concerned.
fn after(byte: u8) State {
    return if (byte == esc) .escape else .ground;
}

// Index just past the next ESC that opens a string at or after `from`, or
// null. One vector pass compares every byte and its successor.
fn findIntroducer(bytes: []const u8, from: usize) ?usize {
    var at = from;
    while (at + vector_len < bytes.len) : (at += vector_len) {
        const current: Bytes = bytes[at..][0..vector_len].*;
        const next: Bytes = bytes[at + 1 ..][0..vector_len].*;
        const escapes = current == @as(Bytes, @splat(esc));
        const opens = (next == @as(Bytes, @splat('_'))) | (next == @as(Bytes, @splat('X'))) |
            (next == @as(Bytes, @splat('^'))) | (next == @as(Bytes, @splat(0x98))) |
            (next == @as(Bytes, @splat(0x9e))) | (next == @as(Bytes, @splat(0x9f)));
        if (@reduce(.Or, escapes & opens)) {
            break;
        }
    }

    while (at + 1 < bytes.len) : (at += 1) {
        if (bytes[at] == esc and opensString(bytes[at + 1])) {
            return at + 2;
        }
    }

    return null;
}

// Index of the next byte that might end the string, or `bytes.len`.
fn findBreak(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at + vector_len <= bytes.len) : (at += vector_len) {
        const chunk: Bytes = bytes[at..][0..vector_len].*;
        const stops = (chunk == @as(Bytes, @splat(can))) | (chunk == @as(Bytes, @splat(sub))) |
            (chunk == @as(Bytes, @splat(esc))) | (chunk >= @as(Bytes, @splat(first_c1)));
        if (@reduce(.Or, stops)) {
            break;
        }
    }

    while (at < bytes.len) : (at += 1) {
        if (!isContent(bytes[at])) {
            return at;
        }
    }

    return bytes.len;
}

fn transitions(self: *ApcFraming, bytes: []const u8, out: []ApcTransition) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (self.advance(bytes, &index)) |transition| {
        out[count] = transition;
        count += 1;
    }

    return count;
}

test "every terminator Ghostty honours ends a Kitty command" {
    const terminators = [_][]const u8{ "\x1b\\", "\x1b", "\x9c", "\x18", "\x1a", "\x80", "\x90", "\x97", "\x99", "\x9b", "\x9d" };
    for (terminators) |terminator| {
        var framing: ApcFraming = .{};
        var out: [4]ApcTransition = undefined;
        var buffer: [64]u8 = undefined;
        const stream = try std.fmt.bufPrint(&buffer, "a\x1b_Ga=T;AAAA{s}", .{terminator});
        try std.testing.expectEqual(@as(usize, 2), transitions(&framing, stream, &out));
        try std.testing.expectEqual(ApcTransition.kitty_ended, out[1]);
        try std.testing.expect(!framing.inKitty());
    }
}

test "ignored bytes neither end nor open anything" {
    var framing: ApcFraming = .{};
    var out: [4]ApcTransition = undefined;
    try std.testing.expectEqual(@as(usize, 1), transitions(&framing, "\x1b_Ga=T;AA\x98\x9e\x9f\xa0\xffAA", &out));
    try std.testing.expect(framing.inKitty());
}

test "X and ^ open Kitty commands like _, and plain text never does" {
    for ([_][]const u8{ "\x1bXGa=T\x1b\\", "\x1b^Ga=T\x1b\\", "\x1b\x9fGa=T\x1b\\" }) |stream| {
        var framing: ApcFraming = .{};
        var out: [4]ApcTransition = undefined;
        try std.testing.expectEqual(@as(usize, 2), transitions(&framing, stream, &out));
    }

    var framing: ApcFraming = .{};
    var out: [4]ApcTransition = undefined;
    try std.testing.expectEqual(@as(usize, 0), transitions(&framing, "snake_case X^_ \xc3\x9f \x1b[1m_ \x1b(B_", &out));
}

test "an interrupted upload ends at the prompt's first escape" {
    var framing: ApcFraming = .{};
    var out: [4]ApcTransition = undefined;
    try std.testing.expectEqual(@as(usize, 1), transitions(&framing, "\x1b_Ga=T,f=100,m=1;iVBORw0KGgo", &out));
    try std.testing.expect(framing.inKitty());
    try std.testing.expectEqual(@as(usize, 1), transitions(&framing, "^C\r\n\x1b[32muser\x1b[0m $ ", &out));
    try std.testing.expectEqual(ApcTransition.kitty_ended, out[0]);
    try std.testing.expect(!framing.inKitty());
}

test "an ESC that ends one command can open the next, at any split" {
    const stream = "\x1b_Ga=t;AAAA\x1b_Ga=p\x1b\\text";
    for (0..stream.len + 1) |split| {
        var framing: ApcFraming = .{};
        var out: [8]ApcTransition = undefined;
        const first = transitions(&framing, stream[0..split], &out);
        const second = transitions(&framing, stream[split..], out[first..]);
        try std.testing.expectEqual(@as(usize, 4), first + second);
    }
}
