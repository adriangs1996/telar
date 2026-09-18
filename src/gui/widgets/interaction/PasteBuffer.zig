//! A complete editor paste, normalized across arbitrary queue chunk boundaries.
//! Overflow discards the whole edit rather than inserting a later tail chunk.
const Buffer = @This();

pub const capacity = 4096;
bytes: [capacity]u8 = undefined,
len: usize = 0,
overflow: bool = false,
after_cr: bool = false,
multiline: bool = false,

/// Example: `buffer.append(chunk);`
pub fn append(buffer: *Buffer, input: []const u8) void {
    if (buffer.overflow) {
        return;
    }

    for (input) |byte| {
        if (byte == '\n' and buffer.after_cr) {
            buffer.after_cr = false;
            continue;
        }

        buffer.after_cr = byte == '\r';
        if (buffer.len == capacity) {
            buffer.overflow = true;
            return;
        }

        buffer.bytes[buffer.len] = if (byte == '\r' or byte == '\n') (if (buffer.multiline) @as(u8, '\n') else ' ') else byte;
        buffer.len += 1;
    }
}

/// Example: `if (buffer.text()) |bytes| commit(bytes);`
pub fn text(buffer: *const Buffer) ?[]const u8 {
    return if (buffer.overflow) null else buffer.bytes[0..buffer.len];
}
