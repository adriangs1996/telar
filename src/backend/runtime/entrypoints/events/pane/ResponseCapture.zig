const Capture = @This();
const Write = @import("ResponseWrite.zig");
starts: usize = 0,
collects: usize = 0,
start_failure: ?anyerror = null,
last_bytes: []const u8 = "",

pub fn start(capture: *Capture, write: Write) !void {
    capture.starts += 1;
    capture.last_bytes = write.bytes;

    if (capture.start_failure) |failure| {
        return failure;
    }
}

pub fn collect(capture: *Capture) void {
    capture.collects += 1;
}
