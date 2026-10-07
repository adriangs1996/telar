//! A complete editor paste, normalized across arbitrary queue chunk boundaries.
//! Overflow keeps the prefix that fits, cut at a UTF-8 boundary, and never
//! a later tail chunk.
const core = @import("telar-core");
const std = @import("std");
const EditorDisplay = @import("EditorDisplay.zig");
const Buffer = @This();

/// The largest text field a window edits, so a paste that fits a field
/// always fits here.
pub const capacity = EditorDisplay.capacity;
pub const limit = core.Limit.declare("gui.widgets.paste_buffer", "pasted bytes", capacity);
// SAFETY: append writes each normalized byte before increasing len; text and UTF-8 trimming inspect only that prefix.
bytes: [capacity]u8 = undefined,
len: usize = 0,
/// The paste was longer than `capacity`; `text` holds its prefix.
overflow: bool = false,
after_cr: bool = false,
multiline: bool = false,

/// Example: `buffer.append(chunk);`
pub fn append(self: *Buffer, input: []const u8) void {
    if (self.overflow) {
        return;
    }

    for (input) |byte| {
        if (byte == '\n' and self.after_cr) {
            self.after_cr = false;
            continue;
        }

        self.after_cr = byte == '\r';
        if (self.len == capacity) {
            self.overflow = true;
            return;
        }

        self.bytes[self.len] = if (byte == '\r' or byte == '\n') (if (self.multiline) @as(u8, '\n') else ' ') else byte;
        self.len += 1;
    }
}

/// The pasted text, or the prefix of it that fit, ending at a UTF-8
/// boundary. Example: `commit(buffer.text());`
pub fn text(self: *const Buffer) []const u8 {
    if (!self.overflow or self.len == 0) {
        return self.bytes[0..self.len];
    }

    // The last sequence may have lost its tail at the capacity.
    var lead = self.len - 1;
    while (lead > 0 and self.bytes[lead] & 0xc0 == 0x80) {
        lead -= 1;
    }

    const needed = std.unicode.utf8ByteSequenceLength(self.bytes[lead]) catch 1;
    return self.bytes[0..if (lead + needed > self.len) lead else self.len];
}
