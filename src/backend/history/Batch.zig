const observer_support = @import("observer_support.zig");
const Batch = @This();

bytes: [observer_support.batch_bytes]u8 = undefined,
len: usize = 0,
events: [observer_support.batch_events]observer_support.Event = undefined,
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

pub fn pushEvent(batch: *Batch, event: observer_support.Event) bool {
    if (batch.event_count == batch.events.len) {
        return false;
    }
    batch.events[batch.event_count] = event;
    batch.event_count += 1;
    return true;
}
