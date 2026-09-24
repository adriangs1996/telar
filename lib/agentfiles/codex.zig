//! The thread name Codex keeps in its state database.
const std = @import("std");
const sqlite = @import("sqlite");
const utf8 = @import("utf8.zig");

const c = sqlite.c;
const thread_name_sql = "SELECT name FROM threads WHERE id = ?1";
const busy_timeout_ms = 200;

/// Reads the name of `thread` with a read-only connection. Codex keeps the
/// database in WAL mode, so a reader never blocks its writer; a busy or
/// missing database, or a thread not yet inserted, reports null. A NULL name
/// reports an empty title. The title borrows `title_buffer`.
///
/// ```zig
/// const name = codex.threadName(path, thread, &title_buffer) orelse return;
/// ```
pub fn threadName(path: []const u8, thread: []const u8, title_buffer: []u8) ?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{path}) catch return null;
    var db: ?*c.sqlite3 = null;
    const opened = if (c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) == c.SQLITE_OK) db else null;
    defer if (db) |handle| {
        _ = c.sqlite3_close(handle);
    };
    const connection = opened orelse return null;
    _ = c.sqlite3_busy_timeout(connection, busy_timeout_ms);

    const statement = sqlite.prepare(connection, thread_name_sql) catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_bind_text(statement, 1, thread.ptr, @intCast(thread.len), null) != c.SQLITE_OK) {
        return null;
    }

    if (c.sqlite3_step(statement) != c.SQLITE_ROW) {
        return null;
    }

    return utf8.truncate(title_buffer, sqlite.columnSlice(statement, 0));
}
