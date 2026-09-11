const Batch = @This();
const source_namespace = @import("root.zig");
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

pub fn pushOutput(batch: *Batch, bytes: []const u8) bool {
    if (bytes.len > batch.bytes.len - batch.len) {
        return false;
    }
    const offset = batch.len;
    @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
    batch.len += bytes.len;

    // Output slices are one byte stream. Merge adjacent PTY reads so the
    // event bound measures output/resize ordering rather than scheduler
    // granularity; TerminalStream is required to be slice-independent.
    if (batch.event_count != 0) {
        switch (batch.events[batch.event_count - 1]) {
            .output => |output| {
                if (@as(usize, output.offset) + output.len == offset) {
                    batch.events[batch.event_count - 1].output.len += @intCast(bytes.len);
                    return true;
                }
            },
            .resize => {},
        }
    }
    if (batch.event_count == batch.events.len) {
        batch.len = offset;
        return false;
    }
    batch.events[batch.event_count] = .{ .output = .{
        .offset = @intCast(offset),
        .len = @intCast(bytes.len),
    } };
    batch.event_count += 1;
    return true;
}

pub fn pushResize(batch: *Batch, size: source_namespace.schema.TerminalSize) bool {
    if (batch.event_count == batch.events.len) {
        return false;
    }
    batch.events[batch.event_count] = .{ .resize = size };
    batch.event_count += 1;
    return true;
}
