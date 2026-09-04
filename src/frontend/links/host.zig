//! Operating-system adapter for opening web links with the default handler.

const std = @import("std");
const builtin = @import("builtin");
const target_mod = @import("target.zig");

const Io = std.Io;

const command_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(5) },
};

/// Opens one HTTP target through the host's registered URL handler.
/// Runs only on a client worker.
///
/// ```zig
/// try open(io, target);
/// ```
pub fn open(io: Io, target: target_mod.Target) !void {
    if (target.scheme != .http and target.scheme != .https) {
        return error.UnsupportedLinkScheme;
    }

    const uri = target.uri();
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/usr/bin/open", uri },
        .linux => &.{ "xdg-open", uri },
        .windows => &.{ "rundll32.exe", "url.dll,FileProtocolHandler", uri },
        else => return error.LinkOpeningUnavailable,
    };
    const gpa = std.heap.page_allocator;
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = command_timeout,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |status| if (status != 0) {
            return error.LinkOpeningFailed;
        },
        else => return error.LinkOpeningFailed,
    }
}
