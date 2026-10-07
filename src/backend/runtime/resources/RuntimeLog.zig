//! The background runtime's own log, `<endpoint>.runtime.log`: its standard
//! error from the moment it holds the listener, so the runtime that owns
//! the socket is the only one that rotates it. It holds reached limits and
//! a fatal error in every build. The previous generation stays as
//! `.runtime.log.1`; the maintenance tick rotates a log past `max_bytes`,
//! so a runtime keeps at most twice that on disk.
const builtin = @import("builtin");
const core = @import("telar-core");
const std = @import("std");
const RuntimeLog = @This();

/// Bytes the log holds before the tick rotates it.
pub const max_bytes = 1024 * 1024;

const stderr_fd: std.c.fd_t = 2;

// SAFETY: openOnto formats the path before publishing path_len; trim does nothing while that length is zero.
path: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
/// The descriptor the log replaces: standard error, or a test's own.
target: std.c.fd_t = stderr_fd,

/// Rotates the previous log and points standard error at a new one. A log
/// that cannot be opened leaves standard error as it was.
///
/// ```zig
/// self.log = RuntimeLog.open(io, endpoint);
/// ```
pub fn open(io: std.Io, endpoint: []const u8) RuntimeLog {
    return openOnto(io, endpoint, stderr_fd);
}

fn openOnto(io: std.Io, endpoint: []const u8, target: std.c.fd_t) RuntimeLog {
    if (comptime builtin.os.tag == .windows) {
        return .{};
    }

    var log: RuntimeLog = .{
        .target = target,
    };
    const path = std.fmt.bufPrint(&log.path, "{s}{s}", .{ endpoint, core.DiagnosticLogName.runtime_log_suffix }) catch return .{};
    log.path_len = path.len;
    log.rotate(io) catch return .{};
    return log;
}

/// Rotates the log once it passes `max_bytes`. One `fstat` a tick.
/// Example: `model.resources.log.trim(model.io);`
pub fn trim(self: *RuntimeLog, io: std.Io) void {
    if (self.path_len == 0) {
        return;
    }

    // `std.Io.File.stat` is `fstat` on macOS and `statx` on Linux, where
    // libc's `fstat` is not declared.
    const log: std.Io.File = .{
        .handle = self.target,
        .flags = .{
            .nonblocking = false,
        },
    };
    const status = log.stat(io) catch return;
    if (status.size < max_bytes) {
        return;
    }

    // Log rotation is best effort; the existing descriptor remains usable if rotation cannot finish.
    self.rotate(io) catch {};
}

fn rotate(self: *RuntimeLog, io: std.Io) !void {
    const path = self.path[0..self.path_len];
    var rotated_buffer: [std.fs.max_path_bytes + core.DiagnosticLogName.rotated_suffix.len]u8 = undefined;
    const rotated = try std.fmt.bufPrint(&rotated_buffer, "{s}{s}", .{ path, core.DiagnosticLogName.rotated_suffix });

    std.Io.Dir.renameAbsolute(path, rotated, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);

    if (std.c.dup2(file.handle, self.target) < 0) {
        return error.LogRedirectFailed;
    }
}
