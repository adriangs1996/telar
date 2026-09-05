//! Read-only adapter for the Codex thread-name database.

const std = @import("std");
const core = @import("telar-core");
const types = @import("types.zig");
const Job = types.Job;
const Completion = types.Completion;
const Io = std.Io;
const schema = core.schema;
const session_file = @import("../session_file.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const thread_name_sql = "SELECT name FROM threads WHERE id = ?1";

/// Example: `probe(job, &completion);`.
/// Reads the thread's current name with a read-only connection. Codex keeps
/// the database in WAL mode, so a reader never blocks its writer; a busy or
/// missing database, or a thread not yet inserted, reports nothing. A NULL
/// name reports an empty title, which clears an earlier agent title.
pub fn probe(job: Job, completion: *Completion) void {
    var path_buffer: [session_file.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "{s}", .{job.watch.pathSlice()}) catch return;
    var db: ?*c.sqlite3 = null;
    const opened = if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) == c.SQLITE_OK) db else null;
    defer if (db) |handle| {
        _ = c.sqlite3_close(handle);
    };
    const connection = opened orelse return;
    _ = c.sqlite3_busy_timeout(connection, 200);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(connection, thread_name_sql, thread_name_sql.len, &stmt, null) != c.SQLITE_OK) {
        return;
    }
    const statement = stmt orelse return;
    defer _ = c.sqlite3_finalize(statement);
    const session = job.watch.session.slice();
    if (c.sqlite3_bind_text(statement, 1, session.ptr, @intCast(session.len), null) != c.SQLITE_OK) {
        return;
    }
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) {
        return;
    }

    var title_buffer: [schema.max_agent_session_title_bytes]u8 = undefined;
    const name = columnText(statement, 0);
    completion.setTitle(schema.truncateSessionTitle(&title_buffer, name));
}

fn columnText(statement: *c.sqlite3_stmt, column: c_int) []const u8 {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) {
        return "";
    }

    const pointer = c.sqlite3_column_text(statement, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(statement, column));
    return pointer[0..len];
}
