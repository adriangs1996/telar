const observer_support = @import("observer_support.zig");
const Batch = @This();

bytes: [observer_support.batch_bytes]u8 = undefined,
len: usize = 0,
events: [observer_support.batch_events]observer_support.Event = undefined,
event_count: usize = 0,
reset_before: bool = false,

pub fn reset(self: *Batch) void {
    self.len = 0;
    self.event_count = 0;
    self.reset_before = false;
}

pub fn pushBytes(self: *Batch, bytes: []const u8) ?u32 {
    if (self.event_count == self.events.len or bytes.len > self.bytes.len - self.len) {
        return null;
    }
    const offset = self.len;
    @memcpy(self.bytes[offset..][0..bytes.len], bytes);
    self.len += bytes.len;
    return @intCast(offset);
}

pub fn pushEvent(self: *Batch, event: observer_support.Event) bool {
    if (self.event_count == self.events.len) {
        return false;
    }
    self.events[self.event_count] = event;
    self.event_count += 1;
    return true;
}
