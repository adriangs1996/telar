const relay = @import("relay.zig");
const std = @import("std");
const BodyCollector = @This();

bytes: [256]u8 = undefined,
len: usize = 0,
stream_id: u32 = 0,
status_code: u16 = 0,
sse_body: bool = false,
activity: usize = 0,
finished: usize = 0,
finished_before_body: bool = false,
request_body: bool = false,
request_finished: usize = 0,

pub fn emit(self: *BodyCollector, event: relay.Event) void {
    switch (event) {
        .lifecycle => |observed| switch (observed.phase) {
            .response_activity => self.activity += 1,
            .response_finished => {
                self.finished_before_body = self.len == 0;
                self.finished += 1;
            },
            else => {},
        },
        .request_headers, .response_headers => {},
        .request_body => |body| {
            std.debug.assert(body.bytes.len <= self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..body.bytes.len], body.bytes);
            self.len += body.bytes.len;
            self.stream_id = body.stream_id;
            self.request_body = true;
        },
        .request_finished => self.request_finished += 1,
        .response_body => |body| {
            std.debug.assert(body.bytes.len <= self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..body.bytes.len], body.bytes);
            self.len += body.bytes.len;
            self.stream_id = body.stream_id;
            self.status_code = body.status_code;
            self.sse_body = body.sse_body;
        },
    }
}

pub fn payloadSlice(self: *const BodyCollector) []const u8 {
    return self.bytes[0..self.len];
}
