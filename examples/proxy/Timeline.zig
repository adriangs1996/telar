const db_ops = @import("db.zig");
const std = @import("std");
const Row = @import("Row.zig");
const Timeline = @This();

db: ?*db_ops.c.sqlite3 = null,
insert: ?*db_ops.c.sqlite3_stmt = null,
session_id: []const u8,

pub const Error = error{ OpenFailed, SchemaFailed, PrepareFailed };

pub fn open(path: [:0]const u8, session_id: []const u8) Error!Timeline {
    var timeline: Timeline = .{ .session_id = session_id };

    if (db_ops.c.sqlite3_open(path.ptr, &timeline.db) != db_ops.c.SQLITE_OK) {
        return error.OpenFailed;
    }
    errdefer _ = db_ops.c.sqlite3_close(timeline.db);
    if (!std.mem.eql(u8, path, ":memory:") and std.c.chmod(path.ptr, 0o600) != 0) {
        return error.OpenFailed;
    }

    if (db_ops.c.sqlite3_exec(timeline.db, db_ops.schema, null, null, null) != db_ops.c.SQLITE_OK) {
        return error.SchemaFailed;
    }
    if (db_ops.c.sqlite3_prepare_v2(timeline.db, db_ops.insert_sql, -1, &timeline.insert, null) != db_ops.c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    return timeline;
}

pub fn close(t: *Timeline) void {
    if (t.insert) |stmt| {
        _ = db_ops.c.sqlite3_finalize(stmt);
    }
    if (t.db) |db| {
        _ = db_ops.c.sqlite3_close(db);
    }
    t.* = .{ .session_id = t.session_id };
}

/// Best effort: a timeline that cannot be written must never take the proxy
/// down with it.
///
/// Callers must pass only deliberately storable text. HTTP bodies are
/// omitted before this seam and terminal output is not persisted.
///
/// Not threadsafe, and does not need to be: every tap publishes through the
/// event queue and the main loop is the only writer. A second writer would
/// need a lock, because `sqlite3_stmt` is not reentrant.
pub fn append(t: *Timeline, row: Row) void {
    const stmt = t.insert orelse return;

    _ = db_ops.c.sqlite3_reset(stmt);

    db_ops.bindText(stmt, 1, t.session_id);
    _ = db_ops.c.sqlite3_bind_int64(stmt, 2, row.at_ms);
    db_ops.bindText(stmt, 3, @tagName(row.kind));
    db_ops.bindInt(stmt, 4, row.ref);
    db_ops.bindOptText(stmt, 5, row.command);
    db_ops.bindInt(stmt, 6, row.exit_status);
    db_ops.bindInt(stmt, 7, row.duration_ms);
    db_ops.bindOptText(stmt, 8, row.host);
    db_ops.bindInt(stmt, 9, row.port);
    db_ops.bindInt(stmt, 10, row.bytes_up);
    db_ops.bindInt(stmt, 11, row.bytes_down);
    db_ops.bindOptText(stmt, 12, row.output);
    db_ops.bindInt(stmt, 13, row.truncated);

    _ = db_ops.c.sqlite3_step(stmt);
    // Bindings hold borrowed pointers (see `bindText`); drop them now so no
    // dangling address survives this call.
    _ = db_ops.c.sqlite3_clear_bindings(stmt);
}
