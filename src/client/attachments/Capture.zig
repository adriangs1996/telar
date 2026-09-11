const Capture = @This();
const CaptureRequest = @import("CaptureRequest.zig");
const std = @import("std");
request: CaptureRequest,
png: []u8,
width: u32,
height: u32,

pub fn deinit(capture: *Capture, gpa: std.mem.Allocator) void {
    if (capture.png.len != 0) {
        std.crypto.secureZero(u8, capture.png);
        gpa.free(capture.png);
    }
    gpa.destroy(capture);
}
