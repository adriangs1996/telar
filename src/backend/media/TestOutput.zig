const SharedFrameView = @import("SharedFrameView.zig");
const FileQueryView = @import("FileQueryView.zig");
const TestOutput = @This();

bytes: [4096]u8 = undefined,
len: usize = 0,
direct: bool = false,
direct_frames: usize = 0,
last_direct: ?SharedFrameView = null,
queries: usize = 0,
last_query_id: u32 = 0,
last_query_len: usize = 0,

pub fn observe(self: *TestOutput, bytes: []const u8) void {
    @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

pub fn observeSharedFrame(self: *TestOutput, frame: SharedFrameView) bool {
    if (!self.direct) {
        return false;
    }
    self.direct_frames += 1;
    self.last_direct = frame;
    return true;
}

pub fn observeFileQuery(self: *TestOutput, query: FileQueryView) bool {
    if (!self.direct) {
        return false;
    }
    self.queries += 1;
    self.last_query_id = query.image_id;
    self.last_query_len = query.byte_len;
    return true;
}

pub fn slice(self: *const TestOutput) []const u8 {
    return self.bytes[0..self.len];
}
