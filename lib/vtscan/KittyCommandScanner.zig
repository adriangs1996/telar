//! Finds where each Kitty graphics command ends in a PTY stream split at
//! arbitrary read boundaries, keeping its control data and the first bytes
//! of its payload, so a caller can act at the exact point a terminal would.
//! Framing follows `KittyFramingCounter`: only ESC-introduced APCs count and
//! only `ESC \` ends one. Runs of bytes that cannot change the state are
//! skipped with a vector search for ESC. Nothing allocates.
const std = @import("std");
const escape_ops = @import("escape.zig");
const KittyCommand = @import("KittyCommand.zig");
const KittyCommandScanner = @This();

/// Control data longer than this is reported truncated.
pub const control_capacity = 256;
/// Enough base64 for a PNG signature and its IHDR dimensions.
pub const payload_capacity = 64;

state: State = .normal,
control: [control_capacity]u8 = undefined,
control_len: usize = 0,
truncated: bool = false,
payload: [payload_capacity]u8 = undefined,
payload_len: usize = 0,

const State = enum { normal, escape, apc_identify, control, control_escape, payload, payload_escape, other, other_escape };

/// The first command that ends inside `bytes`, or null when none does.
/// Call again with `bytes[command.end..]` for the next one.
///
/// ```zig
/// while (scanner.next(rest)) |command| { feed(rest[0..command.end]); rest = rest[command.end..]; }
/// ```
pub fn next(self: *KittyCommandScanner, bytes: []const u8) ?KittyCommand {
    var index: usize = 0;
    while (index < bytes.len) {
        switch (self.state) {
            .normal, .escape => {
                // Only an APC can start a command: jump to the next `ESC _`.
                const start = escape_ops.findApc(bytes, index, self.state == .escape and index == 0) orelse {
                    self.state = if (bytes[bytes.len - 1] == escape_ops.esc) .escape else .normal;
                    return null;
                };
                self.state = .apc_identify;
                index = start;
                continue;
            },
            .other, .payload => {
                const at = std.mem.indexOfScalarPos(u8, bytes, index, escape_ops.esc) orelse bytes.len;
                if (self.state == .payload) {
                    self.capturePayload(bytes[index..at]);
                }

                index = at;
                if (index == bytes.len) {
                    return null;
                }
            },
            else => {},
        }

        const byte = bytes[index];
        index += 1;
        if (self.step(byte)) {
            return .{
                .end = index,
                .control = self.control[0..self.control_len],
                .payload = self.payload[0..self.payload_len],
                .truncated = self.truncated,
            };
        }
    }

    return null;
}

// Advances one byte; true when it ended a Kitty command.
fn step(self: *KittyCommandScanner, byte: u8) bool {
    const esc = escape_ops.esc;
    switch (self.state) {
        .normal => self.state = if (byte == esc) .escape else .normal,
        .escape => self.state = switch (byte) {
            '_' => .apc_identify,
            esc => .escape,
            else => .normal,
        },
        .apc_identify => {
            if (byte == 'G') {
                self.control_len = 0;
                self.payload_len = 0;
                self.truncated = false;
                self.state = .control;
            } else {
                self.state = if (byte == esc) .other_escape else .other;
            }
        },
        .control => switch (byte) {
            ';' => self.state = .payload,
            esc => self.state = .control_escape,
            else => self.captureControl(byte),
        },
        .control_escape => {
            if (byte == '\\') {
                self.state = .normal;
                return true;
            }

            if (byte != esc) {
                self.state = .control;
                self.captureControl(byte);
            }
        },
        .payload => self.state = if (byte == esc) .payload_escape else .payload,
        .payload_escape => {
            if (byte == '\\') {
                self.state = .normal;
                return true;
            }

            if (byte != esc) {
                self.state = .payload;
                self.capturePayload(&.{byte});
            }
        },
        .other => self.state = if (byte == esc) .other_escape else .other,
        .other_escape => self.state = switch (byte) {
            '\\' => .normal,
            esc => .other_escape,
            else => .other,
        },
    }

    return false;
}

fn captureControl(self: *KittyCommandScanner, byte: u8) void {
    if (self.control_len == self.control.len) {
        self.truncated = true;
        return;
    }

    self.control[self.control_len] = byte;
    self.control_len += 1;
}

fn capturePayload(self: *KittyCommandScanner, bytes: []const u8) void {
    const room = self.payload.len - self.payload_len;
    const kept = @min(room, bytes.len);
    @memcpy(self.payload[self.payload_len..][0..kept], bytes[0..kept]);
    self.payload_len += kept;
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
        try std.testing.expectEqual(std.mem.indexOf(u8, stream, "text").?, found[0].end);
        try std.testing.expectEqualStrings("a=T,f=100", found[0].control[0..found[0].control_len]);
        try std.testing.expectEqual(@as(usize, 11), found[0].payload_len);
        try std.testing.expectEqual(stream.len, found[1].end);
        try std.testing.expectEqualStrings("a=d", found[1].control[0..found[1].control_len]);
        try std.testing.expectEqual(@as(usize, 0), found[1].payload_len);
    }
}

test "long control data is truncated and the payload keeps its first bytes" {
    var scanner: KittyCommandScanner = .{};
    var stream: [control_capacity + 200]u8 = undefined;
    stream[0] = escape_ops.esc;
    stream[1] = '_';
    stream[2] = 'G';
    @memset(stream[3 .. control_capacity + 10], 'x');
    stream[control_capacity + 10] = ';';
    @memset(stream[control_capacity + 11 .. stream.len - 2], 'A');
    stream[stream.len - 2] = escape_ops.esc;
    stream[stream.len - 1] = '\\';
    const command = scanner.next(&stream).?;
    try std.testing.expect(command.truncated);
    try std.testing.expectEqual(@as(usize, control_capacity), command.control.len);
    try std.testing.expectEqual(@as(usize, payload_capacity), command.payload.len);
    try std.testing.expectEqual(stream.len, command.end);
}
