const core = @import("telar-core");
const media = @import("media.zig");
const Batch = @This();

bytes: [media.batch_bytes]u8 = undefined,
len: usize = 0,
events: [media.batch_events]media.Event = undefined,
event_count: usize = 0,
reset_before: bool = false,

pub fn reset(self: *Batch) void {
    self.len = 0;
    self.event_count = 0;
    self.reset_before = false;
}

pub fn pushOutput(self: *Batch, bytes: []const u8) bool {
    if (bytes.len > self.bytes.len - self.len) {
        return false;
    }
    const offset = self.len;
    @memcpy(self.bytes[offset..][0..bytes.len], bytes);
    self.len += bytes.len;

    // Output slices are one byte stream. Merge adjacent PTY reads so the
    // event bound measures output/resize ordering rather than scheduler
    // granularity; TerminalStream is required to be slice-independent.
    if (self.event_count != 0) {
        switch (self.events[self.event_count - 1]) {
            .output => |output| {
                if (@as(usize, output.offset) + output.len == offset) {
                    self.events[self.event_count - 1].output.len += @intCast(bytes.len);
                    return true;
                }
            },
            .resize => {},
        }
    }
    if (self.event_count == self.events.len) {
        self.len = offset;
        return false;
    }
    self.events[self.event_count] = .{ .output = .{
        .offset = @intCast(offset),
        .len = @intCast(bytes.len),
    } };
    self.event_count += 1;
    return true;
}

pub fn pushResize(self: *Batch, size: core.TerminalSize) bool {
    if (self.event_count == self.events.len) {
        return false;
    }
    self.events[self.event_count] = .{ .resize = size };
    self.event_count += 1;
    return true;
}
