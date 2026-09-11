const Batch = @This();
const source_namespace = @import("observer_support.zig");
bytes: [source_namespace.batch_bytes]u8 = undefined,
len: usize = 0,
events: [source_namespace.batch_events]source_namespace.Event = undefined,
event_count: usize = 0,
reset_before: bool = false,

pub fn reset(batch: *Batch) void {
    batch.len = 0;
    batch.event_count = 0;
    batch.reset_before = false;
}

pub fn pushBytes(batch: *Batch, bytes: []const u8) ?u32 {
    if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len) {
        return null;
    }
    const offset = batch.len;
    @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
    batch.len += bytes.len;
    return @intCast(offset);
}

pub fn pushEvent(batch: *Batch, event: source_namespace.Event) bool {
    if (batch.event_count == batch.events.len) {
        return false;
    }
    batch.events[batch.event_count] = event;
    batch.event_count += 1;
    return true;
}
