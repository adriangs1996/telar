//! What a diagnostics log's name, `<endpoint>.<role>-<pid>.log` or its
//! rotated `.log.1`, says about the process that wrote it.
const std = @import("std");
const DiagnosticLogName = @This();

/// Suffix of the previous generation of a rotated log.
pub const rotated_suffix = ".1";
/// Suffix of the background runtime's own log, `<endpoint>.runtime.log`:
/// its standard error, in every build. It names no process, so cleanup of
/// ended processes' logs keeps it and a crash stays readable.
pub const runtime_log_suffix = ".runtime.log";

pub const Role = enum { runtime, client };

/// Bytes of the name before `.<role>-<pid>.log`: the endpoint's name.
endpoint_len: usize,
role: Role,
pid: u32,
/// The previous generation, `<name>.log.1`.
rotated: bool,

/// Reads a log's name, or returns null for any other file.
///
/// ```zig
/// const log = DiagnosticLogName.parse("runtime.sock.client-42.log").?; // .client, 42
/// ```
pub fn parse(name: []const u8) ?DiagnosticLogName {
    const rotated = std.mem.endsWith(u8, name, ".log" ++ rotated_suffix);
    const stem_len = if (rotated) name.len - rotated_suffix.len else name.len;
    if (!std.mem.endsWith(u8, name[0..stem_len], ".log")) {
        return null;
    }

    const stem = name[0 .. stem_len - ".log".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    const pid = std.fmt.parseUnsigned(u32, stem[dash + 1 ..], 10) catch return null;
    if (pid == 0) {
        return null;
    }

    const dot = std.mem.lastIndexOfScalar(u8, stem[0..dash], '.') orelse return null;
    const role = std.meta.stringToEnum(Role, stem[dot + 1 .. dash]) orelse return null;
    return .{
        .endpoint_len = dot,
        .role = role,
        .pid = pid,
        .rotated = rotated,
    };
}

test "log names give the endpoint, role and pid of their writer" {
    const plain = parse("runtime.sock.runtime-33843.log").?;
    try std.testing.expectEqual(Role.runtime, plain.role);
    try std.testing.expectEqual(@as(u32, 33843), plain.pid);
    try std.testing.expectEqualStrings("runtime.sock", "runtime.sock.runtime-33843.log"[0..plain.endpoint_len]);
    try std.testing.expect(!plain.rotated);

    const rotated = parse("tlr-e2e.sock.client-7.log.1").?;
    try std.testing.expectEqual(Role.client, rotated.role);
    try std.testing.expect(rotated.rotated);
    try std.testing.expectEqualStrings("tlr-e2e.sock", "tlr-e2e.sock.client-7.log.1"[0..rotated.endpoint_len]);

    try std.testing.expect(parse("runtime.sock.runtime-0.log") == null);
    try std.testing.expect(parse("runtime.sock.gui-1.lock") == null);
    try std.testing.expect(parse("notes.log") == null);
    try std.testing.expect(parse("x.sock.server-4.log") == null);
    try std.testing.expect(parse("x.sock.runtime-4.log.2") == null);
    try std.testing.expect(parse("runtime.sock" ++ runtime_log_suffix) == null);
    try std.testing.expect(parse("my-runtime.sock" ++ runtime_log_suffix) == null);
}
