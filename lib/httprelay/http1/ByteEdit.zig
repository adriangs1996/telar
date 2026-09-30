//! One edit a fuzz target makes to the bytes it generated, so the relay also
//! meets input no generator would write. Only the fuzz roots import it.

const std = @import("std");
const ByteEdit = @This();

pub const Kind = enum {
    replace,
    insert,
    delete,
    insert_line_end,
};

const line_end = "\r\n";

kind: Kind = .replace,
/// Modulo the input's length, plus one for an insertion.
position: u16 = 0,
byte: u8 = 0,

/// Applies `edits` in order to `bytes[0..len]` and returns the new length.
/// An insertion that would outgrow `bytes` is skipped.
///
/// ```zig
/// const len = ByteEdit.applyAll(&buffer, input_len, shape.edits[0..count]);
/// ```
pub fn applyAll(bytes: []u8, len: usize, edits: []const ByteEdit) usize {
    var edited_len = len;
    for (edits) |edit| {
        edited_len = edit.apply(bytes, edited_len);
    }

    return edited_len;
}

fn apply(self: ByteEdit, bytes: []u8, len: usize) usize {
    const position = self.position % (len + 1);
    switch (self.kind) {
        .replace => {
            if (position < len) {
                bytes[position] = self.byte;
            }

            return len;
        },
        .insert => return insert(bytes, len, position, &.{self.byte}),
        .insert_line_end => return insert(bytes, len, position, line_end),
        .delete => {
            if (position == len) {
                return len;
            }

            std.mem.copyForwards(u8, bytes[position .. len - 1], bytes[position + 1 .. len]);
            return len - 1;
        },
    }
}

fn insert(bytes: []u8, len: usize, position: usize, inserted: []const u8) usize {
    if (len + inserted.len > bytes.len) {
        return len;
    }

    std.mem.copyBackwards(u8, bytes[position + inserted.len .. len + inserted.len], bytes[position..len]);
    @memcpy(bytes[position..][0..inserted.len], inserted);
    return len + inserted.len;
}
