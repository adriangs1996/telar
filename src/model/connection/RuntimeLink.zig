//! Whether a client reaches its runtime, as the chrome shows it. A link is
//! connecting until its handshake succeeds, connected while the socket
//! works, and lost from the moment a read or write fails until a new
//! connection succeeds. An attempt that fails for a reason retrying cannot
//! fix leaves it failed until the person asks again. A lost or failed link
//! keeps what failed, so the window can say why it is waiting.
const std = @import("std");
const RuntimeLink = @This();

/// `lost`: a later attempt follows on its own after a backoff.
/// `failed`: no attempt follows until the person asks for one.
/// `stopped`: the window does not keep this machine connected.
pub const Phase = enum { connecting, connected, lost, failed, stopped };

/// The longest failure text kept, in bytes.
pub const max_failure_bytes = 256;
/// The longest machine name kept, in bytes.
pub const max_target_bytes = 255;

/// A UTF-8 continuation byte is `10xxxxxx`.
const continuation_mask: u8 = 0b1100_0000;
const continuation_tag: u8 = 0b1000_0000;

phase: Phase = .connecting,
/// Connection attempts since the link was last connected.
attempt: u16 = 0,
/// Successful connections so far; the second one replaces a session.
sessions: u32 = 0,
failure_bytes: [max_failure_bytes]u8 = undefined,
failure_len: u16 = 0,
/// Whether the failure is one `telar machine setup` repairs: no telar
/// there, or a telar or runtime of another build.
setup_repairs: bool = false,
target_bytes: [max_target_bytes]u8 = undefined,
target_len: u8 = 0,
/// Resyncs a runtime message that stopped at a limit asked for, counted
/// from `limit_resyncs_since_ns`, so one that keeps recurring gives up.
limit_resyncs: u8 = 0,
limit_resyncs_since_ns: u64 = 0,

/// What the last attempt or the lost socket reported, if anything.
pub fn failure(self: *const RuntimeLink) ?[]const u8 {
    if (self.failure_len == 0) {
        return null;
    }

    return self.failure_bytes[0..self.failure_len];
}

/// The machine this link reaches, as people know it.
pub fn target(self: *const RuntimeLink) []const u8 {
    return self.target_bytes[0..self.target_len];
}

/// Names the machine; text past the bound is cut on a UTF-8 boundary.
///
/// ```zig
/// link.name("dev@box");
/// ```
pub fn name(self: *RuntimeLink, text: []const u8) void {
    const kept = boundedUtf8(text, max_target_bytes);
    @memcpy(self.target_bytes[0..kept.len], kept);
    self.target_len = @intCast(kept.len);
}

/// Records why the link failed; text past the bound is cut on a UTF-8
/// boundary, and control bytes become spaces so the chrome draws one line.
///
/// ```zig
/// link.fail("ssh: connect to host box port 22: Connection refused");
/// ```
pub fn fail(self: *RuntimeLink, text: []const u8) void {
    const kept = boundedUtf8(std.mem.trim(u8, text, " \t\r\n"), max_failure_bytes);
    for (kept, 0..) |byte, index| {
        self.failure_bytes[index] = if (byte < ' ' or byte == std.ascii.control_code.del) ' ' else byte;
    }

    self.failure_len = @intCast(kept.len);
}

pub fn clearFailure(self: *RuntimeLink) void {
    self.failure_len = 0;
    self.setup_repairs = false;
}

fn boundedUtf8(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) {
        return if (std.unicode.utf8ValidateSlice(text)) text else "";
    }

    var end = limit;
    while (end > 0 and (text[end] & continuation_mask) == continuation_tag) {
        end -= 1;
    }

    return if (std.unicode.utf8ValidateSlice(text[0..end])) text[0..end] else "";
}

test "failures are one bounded line and names are kept" {
    var link: RuntimeLink = .{};
    link.name("dev@box");
    link.fail("ssh: connect to host box\nport 22: refused\n");

    try std.testing.expectEqualStrings("dev@box", link.target());
    try std.testing.expectEqualStrings("ssh: connect to host box port 22: refused", link.failure().?);

    link.fail("é" ** 200);
    try std.testing.expect(std.unicode.utf8ValidateSlice(link.failure().?));
    try std.testing.expect(link.failure().?.len <= max_failure_bytes);

    link.clearFailure();
    try std.testing.expectEqual(@as(?[]const u8, null), link.failure());
}
