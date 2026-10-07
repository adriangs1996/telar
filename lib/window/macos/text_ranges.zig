const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const c = appkit.c;
const ns_range = @import("Range.zig");
const Range = ns_range.Range;
const not_found: usize = std.math.maxInt(isize);

// The Zig implementations of NSTextInputClient and accessibility call these
// conversions directly. Application offsets count UTF-8 bytes; AppKit counts UTF-16
// code units. Reject offsets inside a code point instead of rounding them.
pub fn utf16Range(text: objc.c.id, start: u32, end: u32) Range {
    const string: c.CFStringRef = @ptrCast(text);
    const first = utf16Offset(string, @min(start, end));
    const last = utf16Offset(string, @max(start, end));
    if (first == not_found or last == not_found) {
        return .{ .location = not_found, .length = 0 };
    }

    return .{ .location = first, .length = last - first };
}

fn utf16Offset(text: c.CFStringRef, offset: u32) usize {
    const length = if (text == null) 0 else c.CFStringGetLength(text);
    var bytes: usize = 0;
    var index: c.CFIndex = 0;
    while (index < length) : (index += 1) {
        if (bytes == offset) {
            return @intCast(index);
        }

        const current = c.CFStringGetCharacterAtIndex(text, index);
        if (std.unicode.utf16IsHighSurrogate(current)) {
            if (index + 1 >= length or !std.unicode.utf16IsLowSurrogate(c.CFStringGetCharacterAtIndex(text, index + 1))) {
                return not_found;
            }

            bytes += 4;
            index += 1;
        } else if (std.unicode.utf16IsLowSurrogate(current)) {
            return not_found;
        } else {
            bytes += std.unicode.utf8CodepointSequenceLength(current) catch return not_found;
        }

        if (bytes > offset) {
            return not_found;
        }
    }

    return if (bytes == offset) @intCast(length) else not_found;
}

// AppKit requests selected and replacement ranges in UTF-16. Convert prefixes
// without allocating substrings; CFStringGetBytes rejects split surrogate pairs.
// Leave both output offsets untouched unless the whole range is representable.
pub fn utf8Range(text: objc.c.id, range: Range, start: *u32, end: *u32) bool {
    if (text == null) {
        return false;
    }

    const string: c.CFStringRef = @ptrCast(text);
    const length: usize = @intCast(c.CFStringGetLength(string));
    if (range.location == not_found or range.location > length or range.length > length - range.location) {
        return false;
    }

    var first: c.CFIndex = 0;
    var last: c.CFIndex = 0;
    const first_range: c.CFRange = .{ .location = 0, .length = @intCast(range.location) };
    const last_range: c.CFRange = .{ .location = 0, .length = @intCast(range.location + range.length) };
    if (c.CFStringGetBytes(string, first_range, c.kCFStringEncodingUTF8, 0, @intFromBool(false), null, 0, &first) != first_range.length or
        c.CFStringGetBytes(string, last_range, c.kCFStringEncodingUTF8, 0, @intFromBool(false), null, 0, &last) != last_range.length or
        last > std.math.maxInt(u32))
    {
        return false;
    }

    start.* = @intCast(first);
    end.* = @intCast(last);
    return true;
}

// IME candidate placement and accessibility bounds start in top-left content
// pixels. Convert to view-local AppKit points; their callers then map to screen.
pub fn contentRect(raw: objc.c.id, x: f64, y: f64, width: f64, height: f64) c.CGRect {
    const view = objc.Object.fromId(raw);
    const window = view.msgSend(objc.c.id, "window", .{});
    const scale = if (window != null) appkit.double(objc.Object.fromId(window), "backingScaleFactor") else 1;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height) or !std.math.isFinite(scale) or scale <= 0) {
        return std.mem.zeroes(c.CGRect);
    }

    var rect: c.CGRect = .{
        .origin = .{ .x = x / scale, .y = y / scale },
        .size = .{ .width = @max(0, width) / scale, .height = @max(0, height) / scale },
    };
    if (!view.msgSend(bool, "isFlipped", .{})) {
        rect.origin.y = view.msgSend(c.CGRect, "bounds", .{}).size.height - (rect.origin.y + rect.size.height);
    }

    return rect;
}
