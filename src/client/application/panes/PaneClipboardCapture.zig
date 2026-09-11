const Capture = @This();

bytes: [32]u8 = undefined,
len: usize = 0,
fail: bool = false,

pub fn set(context: *anyopaque, bytes: []const u8) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    if (capture.fail) {
        return error.ClipboardUnavailable;
    }

    @memcpy(capture.bytes[0..bytes.len], bytes);
    capture.len = bytes.len;
}
