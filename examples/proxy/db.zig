const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// The correlated timeline.
//
// One wide table on purpose. Two taps write into it — the PTY tap and the HTTPS
// proxy — and the whole point of the PoC is to see them interleaved, so keeping
// them in one ordered stream makes the correlation a `WHERE`, not a `JOIN`.
// herdr would normalise this into `command`, `output` and `upstream_request`;
// here the flat shape is what makes the feel obvious.

pub const schema =
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS event (
    \\  id          INTEGER PRIMARY KEY,
    \\  session_id  TEXT    NOT NULL,
    \\  at_ms       INTEGER NOT NULL,
    \\  kind        TEXT    NOT NULL,
    \\  ref         INTEGER,
    \\  command     TEXT,
    \\  exit_status INTEGER,
    \\  duration_ms INTEGER,
    \\  host        TEXT,
    \\  port        INTEGER,
    \\  bytes_up    INTEGER,
    \\  bytes_down  INTEGER,
    \\  output      TEXT,
    \\  truncated   INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS event_at ON event(session_id, at_ms);
;

pub const insert_sql =
    \\INSERT INTO event
    \\  (session_id, at_ms, kind, ref, command, exit_status, duration_ms, host, port, bytes_up, bytes_down, output, truncated)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
;

pub const Row = @import("Row.zig");

pub const Timeline = @import("Timeline.zig");

/// Binds with SQLITE_STATIC (a null destructor): sqlite borrows the bytes
/// instead of copying them. Safe because `append` binds, steps and clears
/// within one call, while the caller's buffers are still alive.
///
/// SQLITE_TRANSIENT would copy, but it is `(sqlite3_destructor_type)-1` in C and
/// Zig's translate-c cannot materialise a function pointer at that address.
pub fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null);
}

pub fn bindOptText(stmt: *c.sqlite3_stmt, index: c_int, text: ?[]const u8) void {
    if (text) |value| {
        bindText(stmt, index, value);
    }
}

pub fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: ?i64) void {
    if (value) |v| {
        _ = c.sqlite3_bind_int64(stmt, index, v);
    }
}

test "timeline database is private" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buffer,
        "{s}/timeline.db",
        .{directory_buffer[0..directory_len]},
    );

    var timeline = try Timeline.open(path, "test-session");
    defer timeline.close();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}
