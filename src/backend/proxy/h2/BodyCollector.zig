const BodyCollector = @This();
const source_namespace = @import("relay.zig");
const std = @import("std");
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

pub fn emit(collector: *BodyCollector, event: source_namespace.Event) void {
    switch (event) {
        .lifecycle => |observed| switch (observed.phase) {
            .response_activity => collector.activity += 1,
            .response_finished => {
                collector.finished_before_body = collector.len == 0;
                collector.finished += 1;
            },
            else => {},
        },
        .request_headers, .response_headers => {},
        .request_body => |body| {
            std.debug.assert(body.bytes.len <= collector.bytes.len - collector.len);
            @memcpy(collector.bytes[collector.len..][0..body.bytes.len], body.bytes);
            collector.len += body.bytes.len;
            collector.stream_id = body.stream_id;
            collector.request_body = true;
        },
        .request_finished => collector.request_finished += 1,
        .response_body => |body| {
            std.debug.assert(body.bytes.len <= collector.bytes.len - collector.len);
            @memcpy(collector.bytes[collector.len..][0..body.bytes.len], body.bytes);
            collector.len += body.bytes.len;
            collector.stream_id = body.stream_id;
            collector.status_code = body.status_code;
            collector.sse_body = body.sse_body;
        },
    }
}

pub fn payloadSlice(collector: *const BodyCollector) []const u8 {
    return collector.bytes[0..collector.len];
}
