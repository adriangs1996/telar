const core = @import("telar-core");
const model = @import("model.zig");
const Segment = @import("Segment.zig");
const SegmentInput = @import("SegmentInput.zig");
const std = @import("std");
const Content = @This();

text_bytes: [model.max_text_bytes]u8 = @splat(0),
text_len: u16 = 0,
segments: [model.max_segments]Segment = @splat(.{}),
segment_count: u8 = 0,

/// Appends one logical segment after validating and compacting its text.
///
/// ```zig
/// try content.append(.{ .text = " CPU", .icon = .cpu });
/// ```
pub fn append(self: *Content, input: SegmentInput) !void {
    if (self.segment_count == model.max_segments) {
        return error.TooManyBarSegments;
    }
    if (input.text.len == 0 and input.icon == null) {
        return error.EmptyBarSegment;
    }
    if (!model.validText(input.text)) {
        return error.InvalidBarText;
    }

    const end = @as(usize, self.text_len) + input.text.len;
    if (end > self.text_bytes.len) {
        return error.BarTextTooLong;
    }

    const offset = self.text_len;
    @memcpy(self.text_bytes[offset..end], input.text);
    self.segments[self.segment_count] = .{
        .text_offset = offset,
        .text_len = @intCast(input.text.len),
        .icon = input.icon,
        .style = input.style,
    };
    self.text_len = @intCast(end);
    self.segment_count += 1;
}

pub fn text(self: *const Content, segment: Segment) []const u8 {
    return self.text_bytes[segment.text_offset..][0..segment.text_len];
}

pub fn slice(self: *const Content) []const Segment {
    return self.segments[0..self.segment_count];
}

pub fn width(self: *const Content) u16 {
    var result: u16 = 0;
    for (self.slice()) |segment| {
        if (segment.icon) |icon| {
            result +|= @max(@as(u16, 1), core.measure(icon.unicodeGlyph()));
        }
        result +|= core.measure(self.text(segment));
    }

    return result;
}

pub fn eql(self: *const Content, right: *const Content) bool {
    if (self.text_len != right.text_len or self.segment_count != right.segment_count) {
        return false;
    }
    if (!std.mem.eql(u8, self.text_bytes[0..self.text_len], right.text_bytes[0..right.text_len])) {
        return false;
    }

    for (self.segments[0..self.segment_count], right.segments[0..right.segment_count]) |left_segment, right_segment| {
        if (!std.meta.eql(left_segment, right_segment)) {
            return false;
        }
    }

    return true;
}
