const capacity = 256;

bytes: [capacity]u8 = undefined,
len: u16 = 0,

/// Returns a bounded prefix ending at a UTF-8 scalar boundary.
/// Example: `const count = PasteChunk.nextSize(remaining);`
pub fn nextSize(text: []const u8) usize {
    if (text.len <= capacity) {
        return text.len;
    }

    var count: usize = capacity;
    while (text[count] & 0xc0 == 0x80) {
        count -= 1;
    }

    return count;
}
