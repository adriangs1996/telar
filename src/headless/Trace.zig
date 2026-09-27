//! What the headless client saw, kept for the exit trace: every delivered
//! pane frame, every input line and mark, and every host request, each
//! stamped with the client's monotonic clock. The ring is allocated once and
//! overwrites its oldest entries, counting what it dropped, so recording
//! never allocates or formats on the measured path.
const std = @import("std");
const Entry = @import("TraceEntry.zig");
const Trace = @This();

/// Entries the ring keeps.
pub const capacity = 1 << 16;

entries: []Entry,
head: usize = 0,
len: usize = 0,
dropped: u64 = 0,

/// Example: `var trace = try Trace.init(gpa);`
pub fn init(gpa: std.mem.Allocator) !Trace {
    return .{ .entries = try gpa.alloc(Entry, capacity) };
}

pub fn deinit(self: *Trace, gpa: std.mem.Allocator) void {
    gpa.free(self.entries);
}

/// Records one entry, overwriting the oldest when full.
///
/// ```zig
/// trace.record(.{ .kind = .frame, .t_ns = now, .pane = 3, .frame = 41 }, "");
/// ```
pub fn record(self: *Trace, entry: Entry, label: []const u8) void {
    const at = (self.head + self.len) % self.entries.len;
    var kept = entry;
    kept.label_len = @intCast(@min(label.len, Entry.label_bytes));
    @memcpy(kept.label[0..kept.label_len], label[0..kept.label_len]);
    self.entries[at] = kept;

    if (self.len < self.entries.len) {
        self.len += 1;
    } else {
        self.head = (self.head + 1) % self.entries.len;
        self.dropped += 1;
    }
}

/// Writes the ring oldest first as one JSON document.
///
/// ```zig
/// try trace.writeJson(writer);
/// ```
pub fn writeJson(self: *const Trace, writer: *std.Io.Writer) !void {
    try writer.print("{{\"dropped\":{d},\"entries\":[", .{self.dropped});
    for (0..self.len) |offset| {
        const entry = &self.entries[(self.head + offset) % self.entries.len];
        if (offset != 0) {
            try writer.writeByte(',');
        }

        try writer.print("{{\"kind\":\"{s}\",\"t_ns\":{d}", .{ @tagName(entry.kind), entry.t_ns });
        if (entry.kind == .frame) {
            try writer.print(",\"pane\":{d},\"frame\":{d}", .{ entry.pane, entry.frame });
        }

        if (entry.label_len != 0) {
            try writer.writeAll(",\"label\":");
            try std.json.Stringify.value(entry.label[0..entry.label_len], .{}, writer);
        }

        try writer.writeByte('}');
    }

    try writer.writeAll("]}\n");
}

test "the ring keeps the newest entries and counts the rest" {
    var trace: Trace = .{ .entries = try std.testing.allocator.alloc(Entry, 2) };
    defer trace.deinit(std.testing.allocator);

    trace.record(.{ .kind = .mark, .t_ns = 1 }, "a");
    trace.record(.{ .kind = .frame, .t_ns = 2, .pane = 3, .frame = 4 }, "");
    trace.record(.{ .kind = .input, .t_ns = 5 }, "key");

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try trace.writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"dropped\":1,\"entries\":[{\"kind\":\"frame\",\"t_ns\":2,\"pane\":3,\"frame\":4},{\"kind\":\"input\",\"t_ns\":5,\"label\":\"key\"}]}\n",
        writer.buffered(),
    );
}
