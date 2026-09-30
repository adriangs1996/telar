//! Finds where each Kitty graphics command ends in a PTY stream split at
//! arbitrary read boundaries, keeping its control data and the first bytes
//! of its payload, so a caller can act at the exact point a terminal would.
//! Framing is Ghostty's (`ApcFraming`): a command ends at ESC, ST, CAN, SUB
//! or a terminating C1 byte, aborted or not, and bytes Ghostty ignores
//! inside it are not kept. Nothing allocates.
const std = @import("std");
const ApcFraming = @import("ApcFraming.zig");
const KittyCommand = @import("KittyCommand.zig");
const KittyCommandScanner = @This();

/// Control data longer than this is reported truncated.
pub const control_capacity = 256;
/// Enough base64 for a PNG signature and its IHDR dimensions.
pub const payload_capacity = 64;

framing: ApcFraming = .{},
/// The current command's `;` was seen: content is payload from here on.
in_payload: bool = false,
control: [control_capacity]u8 = undefined,
control_len: usize = 0,
truncated: bool = false,
payload: [payload_capacity]u8 = undefined,
payload_len: usize = 0,

/// The first command that ends inside `bytes`, or null when none does.
/// Call again with `bytes[command.end..]` for the next one.
///
/// ```zig
/// while (scanner.next(rest)) |command| { feed(rest[0..command.end]); rest = rest[command.end..]; }
/// ```
pub fn next(self: *KittyCommandScanner, bytes: []const u8) ?KittyCommand {
    var index: usize = 0;
    while (true) {
        const start = index;
        const inside = self.framing.inKitty();
        const transition = self.framing.advance(bytes, &index) orelse {
            if (inside) {
                self.capture(bytes[start..]);
            }

            return null;
        };

        switch (transition) {
            .kitty_started => {
                self.in_payload = false;
                self.control_len = 0;
                self.payload_len = 0;
                self.truncated = false;
            },
            .kitty_ended => {
                // The byte before `index` is the terminator.
                self.capture(bytes[start .. index - 1]);
                return .{
                    .end = index,
                    .control = self.control[0..self.control_len],
                    .payload = self.payload[0..self.payload_len],
                    .truncated = self.truncated,
                };
            },
        }
    }
}

// Keeps the command's content: control data up to `;`, then the first
// payload bytes. A long payload is not walked past what is kept.
fn capture(self: *KittyCommandScanner, content: []const u8) void {
    var rest = content;
    if (!self.in_payload) {
        const separator = std.mem.indexOfScalar(u8, rest, ';');
        const control = rest[0 .. separator orelse rest.len];
        for (control) |byte| {
            if (!ApcFraming.isContent(byte)) {
                continue;
            }

            if (self.control_len == self.control.len) {
                self.truncated = true;
                break;
            }

            self.control[self.control_len] = byte;
            self.control_len += 1;
        }

        const at = separator orelse return;
        self.in_payload = true;
        rest = rest[at + 1 ..];
    }

    for (rest) |byte| {
        if (self.payload_len == self.payload.len) {
            return;
        }

        if (ApcFraming.isContent(byte)) {
            self.payload[self.payload_len] = byte;
            self.payload_len += 1;
        }
    }
}

test "commands end at their terminator across every split" {
    const stream = "a\x1b[1mb\x1b_Ga=T,f=100;iVBORw0KGgo\x1b\\text\x1b_Xother\x1b\\\x1b_Ga=d\x1b\\";
    for (0..stream.len + 1) |split| {
        var scanner: KittyCommandScanner = .{};
        var found: [2]struct { end: usize, control: [16]u8, control_len: usize, payload_len: usize } = undefined;
        var count: usize = 0;
        var consumed: usize = 0;
        for ([_][]const u8{ stream[0..split], stream[split..] }) |part| {
            var rest = part;
            var base = consumed;
            while (scanner.next(rest)) |command| {
                found[count] = .{ .end = base + command.end, .control = undefined, .control_len = command.control.len, .payload_len = command.payload.len };
                @memcpy(found[count].control[0..command.control.len], command.control);
                count += 1;
                base += command.end;
                rest = rest[command.end..];
            }

            consumed += part.len;
        }

        try std.testing.expectEqual(@as(usize, 2), count);
        // A command ends at its ESC; the `\\` that follows is the next byte.
        try std.testing.expectEqual(std.mem.indexOf(u8, stream, "text").? - 1, found[0].end);
        try std.testing.expectEqualStrings("a=T,f=100", found[0].control[0..found[0].control_len]);
        try std.testing.expectEqual(@as(usize, 11), found[0].payload_len);
        try std.testing.expectEqual(stream.len - 1, found[1].end);
        try std.testing.expectEqualStrings("a=d", found[1].control[0..found[1].control_len]);
        try std.testing.expectEqual(@as(usize, 0), found[1].payload_len);
    }
}

test "long control data is truncated and the payload keeps its first bytes" {
    var scanner: KittyCommandScanner = .{};
    var stream: [control_capacity + 200]u8 = undefined;
    stream[0] = 0x1b;
    stream[1] = '_';
    stream[2] = 'G';
    @memset(stream[3 .. control_capacity + 10], 'x');
    stream[control_capacity + 10] = ';';
    @memset(stream[control_capacity + 11 .. stream.len - 2], 'A');
    stream[stream.len - 2] = 0x1b;
    stream[stream.len - 1] = '\\';
    const command = scanner.next(&stream).?;
    try std.testing.expect(command.truncated);
    try std.testing.expectEqual(@as(usize, control_capacity), command.control.len);
    try std.testing.expectEqual(@as(usize, payload_capacity), command.payload.len);
    try std.testing.expectEqual(stream.len - 1, command.end);
}

test "an aborted command ends where Ghostty ends it and keeps no ignored bytes" {
    var scanner: KittyCommandScanner = .{};
    const stream = "\x1b_Ga=T,\x9ef=24;AAAA\x18text";
    const command = scanner.next(stream).?;
    try std.testing.expectEqualStrings("a=T,f=24", command.control);
    try std.testing.expectEqualStrings("AAAA", command.payload);
    try std.testing.expectEqualStrings("text", stream[command.end..]);
}
