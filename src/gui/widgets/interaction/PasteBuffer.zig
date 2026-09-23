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

/// Example: `if (buffer.text()) |bytes| commit(bytes);`
pub fn text(self: *const Buffer) ?[]const u8 {
    return if (self.overflow) null else self.bytes[0..self.len];
}
