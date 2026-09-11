const Timeline = @This();
const source_namespace = @import("db.zig");
const std = @import("std");
const Row = @import("Row.zig");
db: ?*source_namespace.c.sqlite3 = null,
insert: ?*source_namespace.c.sqlite3_stmt = null,
session_id: []const u8,

pub const Error = error{ OpenFailed, SchemaFailed, PrepareFailed };

pub fn open(path: [:0]const u8, session_id: []const u8) Error!Timeline {
    var timeline: Timeline = .{ .session_id = session_id };

    if (source_namespace.c.sqlite3_open(path.ptr, &timeline.db) != source_namespace.c.SQLITE_OK) {
        return error.OpenFailed;
    }
    errdefer _ = source_namespace.c.sqlite3_close(timeline.db);
    if (!std.mem.eql(u8, path, ":memory:") and std.c.chmod(path.ptr, 0o600) != 0) {
        return error.OpenFailed;
    }

    if (source_namespace.c.sqlite3_exec(timeline.db, source_namespace.schema, null, null, null) != source_namespace.c.SQLITE_OK) {
        return error.SchemaFailed;
    }
    if (source_namespace.c.sqlite3_prepare_v2(timeline.db, source_namespace.insert_sql, -1, &timeline.insert, null) != source_namespace.c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    return timeline;
}

pub fn close(t: *Timeline) void {
    if (t.insert) |stmt| {
        _ = source_namespace.c.sqlite3_finalize(stmt);
    }
    if (t.db) |db| {
        _ = source_namespace.c.sqlite3_close(db);
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

    _ = source_namespace.c.sqlite3_reset(stmt);

    source_namespace.bindText(stmt, 1, t.session_id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, row.at_ms);
    source_namespace.bindText(stmt, 3, @tagName(row.kind));
    source_namespace.bindInt(stmt, 4, row.ref);
    source_namespace.bindOptText(stmt, 5, row.command);
    source_namespace.bindInt(stmt, 6, row.exit_status);
    source_namespace.bindInt(stmt, 7, row.duration_ms);
    source_namespace.bindOptText(stmt, 8, row.host);
    source_namespace.bindInt(stmt, 9, row.port);
    source_namespace.bindInt(stmt, 10, row.bytes_up);
    source_namespace.bindInt(stmt, 11, row.bytes_down);
    source_namespace.bindOptText(stmt, 12, row.output);
    source_namespace.bindInt(stmt, 13, row.truncated);

    _ = source_namespace.c.sqlite3_step(stmt);
    // Bindings hold borrowed pointers (see `bindText`); drop them now so no
    // dangling address survives this call.
    _ = source_namespace.c.sqlite3_clear_bindings(stmt);
}
