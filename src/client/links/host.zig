//! Operating-system adapter for opening allowlisted URLs with the default handler.

const data = @import("model");
const std = @import("std");
const builtin = @import("builtin");

const command_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(5) },
};

/// Opens one classified external target through the host's registered handler.
/// Runs only on a client worker.
///
/// ```zig
/// try open(io, target);
/// ```
pub fn open(io: std.Io, target: data.LinkTarget) !void {
    // Files and paths open in an editor pane, never through the desktop.
    if (target.scheme == .file or target.scheme == .path) {
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

test "host URL worker rejects non-web schemes before spawning a process" {
    try std.testing.expectError(error.UnsupportedLinkScheme, open(std.testing.io, try data.LinkTarget.init("file:///tmp/example.txt")));
}
