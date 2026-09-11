const Capture = @This();
const source_namespace = @import("sse.zig");
const CapturedEvent = @import("CapturedEvent.zig");
const Event = @import("SseEvent.zig");
const std = @import("std");
events: [source_namespace.max_captured_events]CapturedEvent = @splat(.{}),
len: usize = 0,

pub fn emit(capture: *Capture, event: Event) void {
    std.debug.assert(capture.len < capture.events.len);
    std.debug.assert(event.name.len <= source_namespace.max_event_name_bytes);
    std.debug.assert(event.data.len <= source_namespace.max_data_bytes);

    const destination = &capture.events[capture.len];
    @memcpy(destination.name[0..event.name.len], event.name);
    destination.name_len = event.name.len;
    @memcpy(destination.data[0..event.data.len], event.data);
    destination.data_len = event.data.len;
    destination.truncated = event.truncated;
    capture.len += 1;
}
