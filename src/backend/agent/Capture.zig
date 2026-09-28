const vtscan = @import("vtscan");
const InputScanner = vtscan.InputScanner;
const description = @import("description.zig");
const std = @import("std");
const Capture = @This();

scanner: InputScanner = .{},
bytes: [description.max_query_bytes]u8 = undefined,
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
pub fn feed(self: *Capture, input: []const u8) bool {
    if (self.submitted) {
        return false;
    }
    for (input) |byte| {
        if (self.len < self.bytes.len) {
            self.bytes[self.len] = byte;
            self.len += 1;
        } else {
            self.truncated = true;
        }
        const event = self.scanner.feed(&.{byte});
        if (event.cancelled) {
            self.clear();
            continue;
        }
        if (event.submitted) {
            self.submitted = true;
            return true;
        }
    }
    return false;
}

pub fn raw(self: *const Capture) []const u8 {
    return self.bytes[0..self.len];
}

pub fn clear(self: *Capture) void {
    std.crypto.secureZero(u8, self.bytes[0..self.len]);
    self.* = .{};
}
