//! A selection transfer detached from Wayland. The window negotiates image/png
//! and lends the read end to one media worker; no proxy crosses threads.
const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const Limits = @import("../ClipboardLimits.zig");
const ClipboardSource = @This();
const timeout_ms = 5000;
const chunk_bytes = 16 * 1024;
fd: c_int,

pub fn deinit(self: *ClipboardSource) void {
    _ = c.close(self.fd);
    self.* = undefined;
}

/// Reads one bounded binary transfer on the media worker. A silent or stalled
/// provider expires after five seconds; EOF is required and partial data never
/// becomes an attachment. The GUI validates PNG dimensions before decoding.
pub fn read(self: ClipboardSource, gpa: std.mem.Allocator, limits: Limits) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, bytes.items);
        bytes.deinit(gpa);
    }
    const deadline = try now() + timeout_ms;
    var chunk: [chunk_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &chunk);
    while (true) {
        const remaining = deadline - try now();
        if (remaining <= 0) {
            return error.ClipboardReadFailed;
        }
        var pollfd: c.struct_pollfd = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pollfd, 1, @intCast(remaining));
        if (ready < 0 and c.__errno_location().* == c.EINTR) {
            continue;
        }
        if (ready <= 0 or pollfd.revents & (c.POLLERR | c.POLLNVAL) != 0) {
            return error.ClipboardReadFailed;
        }
        const count = c.read(self.fd, &chunk, chunk.len);
        if (count < 0) {
            if (c.__errno_location().* == c.EINTR or c.__errno_location().* == c.EAGAIN) {
                continue;
            }
            return error.ClipboardReadFailed;
        }
        if (count == 0) {
            if (bytes.items.len == 0) {
                return error.NoImageOnClipboard;
            }
            return bytes.toOwnedSlice(gpa);
        }
        const len: usize = @intCast(count);
        if (len > limits.source_bytes -| bytes.items.len) {
            return error.ClipboardSourceTooLarge;
        }
        if (len > limits.png_bytes -| bytes.items.len) {
            return error.ClipboardPngTooLarge;
        }
        const limit = @min(limits.source_bytes, limits.png_bytes);
        const capacity = @min(limit, @max(bytes.items.len + len, bytes.capacity +| (bytes.capacity / 2) +| chunk_bytes));
        try bytes.ensureTotalCapacityPrecise(gpa, capacity);
        bytes.appendSliceAssumeCapacity(chunk[0..len]);
    }
}

fn now() !i64 {
    // SAFETY: clock_gettime fills time on success; failure returns before either field is read.
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) {
        return error.ClockFailed;
    }
    return time.tv_sec * std.time.ms_per_s + @divTrunc(time.tv_nsec, std.time.ns_per_ms);
}
