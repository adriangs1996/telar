const window_title = @import("window_title.zig");
const Capture = @This();

count: usize = 0,
fail: bool = false,
text: [window_title.max_title_bytes]u8 = undefined,
len: usize = 0,

pub fn set(context: *anyopaque, title: []const u8) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    if (capture.fail) {
        return error.TitleFailed;
    }

    @memcpy(capture.text[0..title.len], title);
    capture.len = title.len;
    capture.count += 1;
}
