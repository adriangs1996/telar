//! Byte-bounded copies that never split a UTF-8 sequence.

/// Copies as much of `value` as fits in `buffer`, backing off to the start
/// of a codepoint.
///
/// ```zig
/// const title = utf8.truncate(&buffer, name);
/// ```
pub fn truncate(buffer: []u8, value: []const u8) []const u8 {
    var len = @min(value.len, buffer.len);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    @memcpy(buffer[0..len], value[0..len]);
    return buffer[0..len];
}
