//! What one command run over SSH printed and how it ended. The caller owns
//! both outputs and frees them with `deinit`.
const core = @import("telar-core");
const std = @import("std");
const limit_reached = @import("limit_reached.zig");
const ScriptOutput = @This();

/// Newest bytes of standard output kept. An installer may print any
/// amount; what callers parse is a few lines.
pub const kept_stdout_bytes = 256 * 1024;
const stdout_limit = core.Limit.declare("machines.remote_shell_stdout_bytes", "bytes", kept_stdout_bytes);

term: std.process.Child.Term,
stdout: []u8,
stderr: []u8,
/// Bytes printed before `stdout` that its bound dropped.
stdout_dropped: u64 = 0,

pub fn deinit(self: *const ScriptOutput, gpa: std.mem.Allocator) void {
    gpa.free(self.stdout);
    gpa.free(self.stderr);
}

/// OpenSSH's own failures exit 255 (ssh(1), EXIT STATUS).
const SshExit = enum(u8) {
    failed = 255,
    _,
};

/// Standard output whole, for a caller that parses it from the start. When
/// its first bytes were dropped the limit is named and the parse refused,
/// so a cut path or a missing hook is never read as an answer.
///
/// ```zig
/// const platform = try MachinePlatform.parse(try output.wholeStdout());
/// ```
pub fn wholeStdout(self: *const ScriptOutput) ![]const u8 {
    if (self.stdout_dropped != 0) {
        limit_reached.report(.{
            .limit = stdout_limit,
            .requested = self.stdout.len + self.stdout_dropped,
        });
        return error.RemoteOutputTooLong;
    }

    return self.stdout;
}

/// Whether the command exited with status 0.
pub fn succeeded(self: *const ScriptOutput) bool {
    return self.term == .exited and self.term.exited == 0;
}

/// Whether `ssh` itself failed or was killed, so the command's own status
/// says nothing: a status check must not read it as "not logged in".
pub fn sshFailed(self: *const ScriptOutput) bool {
    return self.term != .exited or self.term.exited == @intFromEnum(SshExit.failed);
}

/// The last line the command printed on standard error: what an installer
/// or `ssh` says last is why it stopped.
///
/// ```zig
/// try report.end(.telar, .failed, "{s}", .{output.errorLine()});
/// ```
pub fn errorLine(self: *const ScriptOutput) []const u8 {
    const trimmed = std.mem.trimEnd(u8, self.stderr, " \r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |at| at + 1 else 0;
    return trimmed[start..];
}

test "the error line is the last one printed" {
    var stderr = "warning: slow\nfatal: refused\n\n".*;
    const output: ScriptOutput = .{
        .term = .{ .exited = 1 },
        .stdout = &.{},
        .stderr = &stderr,
    };

    try std.testing.expectEqualStrings("fatal: refused", output.errorLine());
    try std.testing.expect(!output.succeeded());
}

test "ssh's own failure is told from the command's" {
    const refused: ScriptOutput = .{
        .term = .{ .exited = 255 },
        .stdout = &.{},
        .stderr = &.{},
    };
    const answered: ScriptOutput = .{
        .term = .{ .exited = 1 },
        .stdout = &.{},
        .stderr = &.{},
    };
    try std.testing.expect(refused.sshFailed());
    try std.testing.expect(!answered.sshFailed());
}

test "a parser gets standard output only when none of it was dropped" {
    var stdout = "linked\n".*;
    var output: ScriptOutput = .{
        .term = .{
            .exited = 0,
        },
        .stdout = &stdout,
        .stderr = &.{},
    };
    try std.testing.expectEqualStrings("linked\n", try output.wholeStdout());

    output.stdout_dropped = 1;
    try std.testing.expectError(error.RemoteOutputTooLong, output.wholeStdout());
}
