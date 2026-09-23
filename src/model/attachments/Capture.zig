const CaptureRequest = @import("CaptureRequest.zig");
const std = @import("std");
const Capture = @This();

request: CaptureRequest,
png: []u8,
width: u32,
height: u32,

pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
    if (self.png.len != 0) {
        std.crypto.secureZero(u8, self.png);
        gpa.free(self.png);
    }
    gpa.destroy(self);
}
