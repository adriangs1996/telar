const Capture = @This();
const source_namespace = @import("window_title.zig");
count: usize = 0,
fail: bool = false,
text: [source_namespace.max_title_bytes]u8 = undefined,
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
