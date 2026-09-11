const model = @import("model.zig");
const Segment = @import("Segment.zig");
const SegmentInput = @import("SegmentInput.zig");
const measure_module = @import("telar-core").measure;
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
pub fn append(content: *Content, input: SegmentInput) !void {
    if (content.segment_count == model.max_segments) {
        return error.TooManyBarSegments;
    }
    if (input.text.len == 0 and input.icon == null) {
        return error.EmptyBarSegment;
    }
    if (!model.validText(input.text)) {
        return error.InvalidBarText;
    }

    const end = @as(usize, content.text_len) + input.text.len;
    if (end > content.text_bytes.len) {
        return error.BarTextTooLong;
    }

    const offset = content.text_len;
    @memcpy(content.text_bytes[offset..end], input.text);
    content.segments[content.segment_count] = .{
        .text_offset = offset,
        .text_len = @intCast(input.text.len),
        .icon = input.icon,
        .style = input.style,
    };
    content.text_len = @intCast(end);
    content.segment_count += 1;
}

pub fn text(content: *const Content, segment: Segment) []const u8 {
    return content.text_bytes[segment.text_offset..][0..segment.text_len];
}

pub fn slice(content: *const Content) []const Segment {
    return content.segments[0..content.segment_count];
}

pub fn width(content: *const Content) u16 {
    var result: u16 = 0;
    for (content.slice()) |segment| {
        if (segment.icon) |icon| {
            result +|= @max(@as(u16, 1), measure_module(icon.unicodeGlyph()));
        }
        result +|= measure_module(content.text(segment));
    }

    return result;
}

pub fn eql(left: *const Content, right: *const Content) bool {
    if (left.text_len != right.text_len or left.segment_count != right.segment_count) {
        return false;
    }
    if (!std.mem.eql(u8, left.text_bytes[0..left.text_len], right.text_bytes[0..right.text_len])) {
        return false;
    }

    for (left.segments[0..left.segment_count], right.segments[0..right.segment_count]) |left_segment, right_segment| {
        if (!std.meta.eql(left_segment, right_segment)) {
            return false;
        }
    }

    return true;
}
