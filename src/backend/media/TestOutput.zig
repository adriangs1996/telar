const TestOutput = @This();
const SharedFrameView = @import("SharedFrameView.zig");
const FileQueryView = @import("FileQueryView.zig");
bytes: [4096]u8 = undefined,
len: usize = 0,
direct: bool = false,
direct_frames: usize = 0,
last_direct: ?SharedFrameView = null,
queries: usize = 0,
last_query_id: u32 = 0,
last_query_len: usize = 0,

pub fn observe(output: *TestOutput, bytes: []const u8) void {
    @memcpy(output.bytes[output.len..][0..bytes.len], bytes);
    output.len += bytes.len;
}

pub fn observeSharedFrame(output: *TestOutput, frame: SharedFrameView) bool {
    if (!output.direct) {
        return false;
    }
    output.direct_frames += 1;
    output.last_direct = frame;
    return true;
}

pub fn observeFileQuery(output: *TestOutput, query: FileQueryView) bool {
    if (!output.direct) {
        return false;
    }
    output.queries += 1;
    output.last_query_id = query.image_id;
    output.last_query_len = query.byte_len;
    return true;
}

pub fn slice(output: *const TestOutput) []const u8 {
    return output.bytes[0..output.len];
}
