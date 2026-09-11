const Capture = @This();
const escape = @import("../history/escape.zig");
const source_namespace = @import("description.zig");
const std = @import("std");
scanner: escape.InputScanner = .{},
bytes: [source_namespace.max_query_bytes]u8 = undefined,
len: u16 = 0,
truncated: bool = false,
submitted: bool = false,

/// Returns true exactly once, when the first non-cancelled submit lands.
///
/// ```zig
/// if (capture.feed(input)) {
///     startGeneration(capture.raw());
/// }
/// ```
pub fn feed(capture: *Capture, input: []const u8) bool {
    if (capture.submitted) {
        return false;
    }
    for (input) |byte| {
        if (capture.len < capture.bytes.len) {
            capture.bytes[capture.len] = byte;
            capture.len += 1;
        } else {
            capture.truncated = true;
        }
        const event = capture.scanner.feed(&.{byte});
        if (event.cancelled) {
            capture.clear();
            continue;
        }
        if (event.submitted) {
            capture.submitted = true;
            return true;
        }
    }
    return false;
}

pub fn raw(capture: *const Capture) []const u8 {
    return capture.bytes[0..capture.len];
}

pub fn clear(capture: *Capture) void {
    std.crypto.secureZero(u8, capture.bytes[0..capture.len]);
    capture.* = .{};
}
