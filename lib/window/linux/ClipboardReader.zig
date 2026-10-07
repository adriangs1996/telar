const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const ClipboardReader = @This();
const timeout_ms = 5000;
const read_budget = 16 * 1024;
const attempt_limit = 16;
const chunk_size = 4096;

fd: c_int = -1,
pending: bool = false,
ready: bool = false,
request_id: u64 = 0,
deadline_ms: i64 = 0,
status: Status = .success,
len: usize = 0,
// SAFETY: read copies each chunk before increasing len; validation and successful clipboard events expose only bytes[0..len].
bytes: [c.TELAR_GUI_CLIPBOARD_CAPACITY]u8 = undefined,

pub const Status = enum(u32) { success, unavailable, too_large, cancelled };

/// Takes the read descriptor only on success; the complete bounded result stays
/// owned until the window admits its event and calls release.
pub fn begin(self: *ClipboardReader, fd: c_int, request_id: u64, now: i64) bool {
    if (self.pending or fd < 0) {
        return false;
    }

    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0 or c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) {
        return false;
    }

    self.fd = fd;
    self.pending = true;
    self.ready = false;
    self.request_id = request_id;
    self.deadline_ms = now + timeout_ms;
    self.len = 0;
    return true;
}

/// Advances nonblocking reads with a byte and syscall budget. EOF validates the
/// entire UTF-8 result; errors and oversize transfers expose no partial paste.
pub fn read(self: *ClipboardReader, now: i64) void {
    if (!self.pending or self.ready) {
        return;
    }

    if (now >= self.deadline_ms) {
        self.finish(.unavailable);
        return;
    }

    var chunk: [chunk_size]u8 = undefined;
    var remaining: usize = read_budget;
    for (0..attempt_limit) |_| {
        if (remaining == 0) {
            return;
        }

        const count = c.read(self.fd, &chunk, @min(remaining, chunk.len));
        if (count < 0) {
            switch (c.__errno_location().*) {
                c.EINTR => continue,
                c.EAGAIN => return,
                else => self.finish(.unavailable),
            }
            return;
        }

        if (count == 0) {
            self.finish(if (std.unicode.utf8ValidateSlice(self.bytes[0..self.len])) .success else .unavailable);
            return;
        }

        const len: usize = @intCast(count);
        if (len > self.bytes.len - self.len) {
            self.finish(.too_large);
            return;
        }

        @memcpy(self.bytes[self.len..][0..len], chunk[0..len]);
        self.len += len;
        remaining -= len;
    }
}

fn finish(self: *ClipboardReader, status: Status) void {
    if (self.fd >= 0) {
        _ = c.close(self.fd);
        self.fd = -1;
    }
    self.ready = true;
    self.status = status;
    if (status != .success) {
        self.len = 0;
    }
}

pub fn cancel(self: *ClipboardReader) void {
    if (self.pending) {
        self.finish(.cancelled);
    }
}

pub fn release(self: *ClipboardReader) void {
    if (self.fd >= 0) {
        _ = c.close(self.fd);
    }
    self.fd = -1;
    self.pending = false;
    self.ready = false;
    self.len = 0;
}

pub fn timeout(self: *const ClipboardReader, now: i64) c_int {
    return if (!self.pending or self.ready) -1 else @intCast(std.math.clamp(self.deadline_ms - now, 0, timeout_ms));
}
