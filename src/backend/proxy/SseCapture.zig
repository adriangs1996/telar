const sse = @import("sse.zig");
const CapturedEvent = @import("CapturedEvent.zig");
const SseEvent = @import("SseEvent.zig");
const std = @import("std");
const Capture = @This();

events: [sse.max_captured_events]CapturedEvent = @splat(.{}),
len: usize = 0,

pub fn emit(capture: *Capture, event: SseEvent) void {
    std.debug.assert(capture.len < capture.events.len);
    std.debug.assert(event.name.len <= sse.max_event_name_bytes);
    std.debug.assert(event.data.len <= sse.max_data_bytes);

    const destination = &capture.events[capture.len];
    @memcpy(destination.name[0..event.name.len], event.name);
    destination.name_len = event.name.len;
    @memcpy(destination.data[0..event.data.len], event.data);
    destination.data_len = event.data.len;
    destination.truncated = event.truncated;
    capture.len += 1;
}
