//! What one command run over SSH printed and how it ended. The caller owns
//! both outputs and frees them with `deinit`.
const std = @import("std");
const ScriptOutput = @This();

term: std.process.Child.Term,
stdout: []u8,
stderr: []u8,

pub fn deinit(self: *const ScriptOutput, gpa: std.mem.Allocator) void {
    gpa.free(self.stdout);
    gpa.free(self.stderr);
}

/// OpenSSH's own failures exit 255 (ssh(1), EXIT STATUS).
const SshExit = enum(u8) {
    failed = 255,
    _,
};

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
