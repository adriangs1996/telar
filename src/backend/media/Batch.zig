const core = @import("telar-core");
const std = @import("std");
const media = @import("media.zig");
const Batch = @This();

bytes: [media.batch_bytes]u8 = undefined,
len: usize = 0,
events: [media.batch_events]media.Event = undefined,
event_count: usize = 0,
reset_before: bool = false,
/// Some of the output belongs to a Kitty graphics command.
kitty: bool = false,

pub fn reset(self: *Batch) void {
    self.len = 0;
    self.event_count = 0;
    self.reset_before = false;
    self.kitty = false;
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
    // Only the last of consecutive resizes matters to the emulator.
    if (self.event_count != 0) {
        switch (self.events[self.event_count - 1]) {
            .resize => {
                self.events[self.event_count - 1] = .{ .resize = size };
                return true;
            },
            .output => {},
        }
    }

    if (self.event_count == self.events.len) {
        return false;
    }
    self.events[self.event_count] = .{ .resize = size };
    self.event_count += 1;
    return true;
}

test "consecutive resizes fold into one event" {
    var batch: Batch = .{};
    try std.testing.expect(batch.pushOutput("text"));
    try std.testing.expect(batch.pushResize(.{ .cols = 10, .rows = 5 }));
    try std.testing.expect(batch.pushResize(.{ .cols = 20, .rows = 6 }));
    try std.testing.expectEqual(@as(usize, 2), batch.event_count);
    try std.testing.expectEqual(@as(u16, 20), batch.events[1].resize.cols);
    try std.testing.expect(batch.pushOutput("more"));
    try std.testing.expect(batch.pushResize(.{ .cols = 30, .rows = 7 }));
    try std.testing.expectEqual(@as(usize, 4), batch.event_count);
}
