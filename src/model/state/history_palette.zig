//! Bounded storage for the latest history-palette results. The palette only
//! shows the newest reply for the newest query, so stale replies are ignored
//! by request id instead of queued.

pub const max_command_bytes = 512;
pub const max_entry_cwd_bytes = 256;
pub const max_command_storage = 768 * 1024;

pub fn copyBounded(buffer: []u8, source: []const u8) u16 {
    var len = @min(buffer.len, source.len);
    while (len < source.len and len > 0 and source[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    @memcpy(buffer[0..len], source[0..len]);
    return @intCast(len);
}
