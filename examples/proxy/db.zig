const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

// The correlated timeline.
//
// One wide table on purpose. Two taps write into it — the PTY tap and the HTTPS
// proxy — and the whole point of the PoC is to see them interleaved, so keeping
// them in one ordered stream makes the correlation a `WHERE`, not a `JOIN`.
// herdr would normalise this into `command`, `output` and `upstream_request`;
// here the flat shape is what makes the feel obvious.

const schema =
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

const insert_sql =
    \\INSERT INTO event
    \\  (session_id, at_ms, kind, ref, command, exit_status, duration_ms, host, port, bytes_up, bytes_down, output, truncated)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
;

/// One row. Every tap fills the columns it owns and leaves the rest null.
pub const Row = struct {
    at_ms: i64,
    kind: Kind,
    /// Command id or connection id, so an `opened`/`closed` pair can be joined.
    ref: ?i64 = null,
    command: ?[]const u8 = null,
    exit_status: ?i64 = null,
    duration_ms: ?i64 = null,
    host: ?[]const u8 = null,
    port: ?i64 = null,
    bytes_up: ?i64 = null,
    bytes_down: ?i64 = null,
    /// Resolved text the command printed. Redaction belongs here, before the
    /// bytes reach disk — see the note in `Timeline.append`.
    output: ?[]const u8 = null,
    truncated: ?i64 = null,

    pub const Kind = enum {
        command_started,
        command_finished,
        upstream_opened,
        upstream_closed,
        upstream_exchange,
    };
};

pub const Timeline = struct {
    db: ?*c.sqlite3 = null,
    insert: ?*c.sqlite3_stmt = null,
    session_id: []const u8,

    pub const Error = error{ OpenFailed, SchemaFailed, PrepareFailed };

    pub fn open(path: [:0]const u8, session_id: []const u8) Error!Timeline {
        var timeline: Timeline = .{ .session_id = session_id };

        if (c.sqlite3_open(path.ptr, &timeline.db) != c.SQLITE_OK) return error.OpenFailed;
        errdefer _ = c.sqlite3_close(timeline.db);

        if (c.sqlite3_exec(timeline.db, schema, null, null, null) != c.SQLITE_OK) {
            return error.SchemaFailed;
        }
        if (c.sqlite3_prepare_v2(timeline.db, insert_sql, -1, &timeline.insert, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }

        return timeline;
    }

    pub fn close(t: *Timeline) void {
        if (t.insert) |stmt| _ = c.sqlite3_finalize(stmt);
        if (t.db) |db| _ = c.sqlite3_close(db);
        t.* = .{ .session_id = t.session_id };
    }

    /// Best effort: a timeline that cannot be written must never take the proxy
    /// down with it.
    ///
    /// REDACTION SEAM: `row.output` is unfiltered terminal text and routinely
    /// contains tokens, connection strings and whatever a command printed from
    /// the environment. Nothing here strips them yet. That has to land before
    /// this database is trusted, and it belongs here — at the write, not at the
    /// read, because a read-side filter still leaves the secret on disk.
    ///
    /// Not threadsafe, and does not need to be: every tap publishes through the
    /// event queue and the main loop is the only writer. A second writer would
    /// need a lock, because `sqlite3_stmt` is not reentrant.
    pub fn append(t: *Timeline, row: Row) void {
        const stmt = t.insert orelse return;

        _ = c.sqlite3_reset(stmt);

        bindText(stmt, 1, t.session_id);
        _ = c.sqlite3_bind_int64(stmt, 2, row.at_ms);
        bindText(stmt, 3, @tagName(row.kind));
        bindInt(stmt, 4, row.ref);
        bindOptText(stmt, 5, row.command);
        bindInt(stmt, 6, row.exit_status);
        bindInt(stmt, 7, row.duration_ms);
        bindOptText(stmt, 8, row.host);
        bindInt(stmt, 9, row.port);
        bindInt(stmt, 10, row.bytes_up);
        bindInt(stmt, 11, row.bytes_down);
        bindOptText(stmt, 12, row.output);
        bindInt(stmt, 13, row.truncated);

        _ = c.sqlite3_step(stmt);
        // Bindings hold borrowed pointers (see `bindText`); drop them now so no
        // dangling address survives this call.
        _ = c.sqlite3_clear_bindings(stmt);
    }
};

/// Binds with SQLITE_STATIC (a null destructor): sqlite borrows the bytes
/// instead of copying them. Safe because `append` binds, steps and clears
/// within one call, while the caller's buffers are still alive.
///
/// SQLITE_TRANSIENT would copy, but it is `(sqlite3_destructor_type)-1` in C and
/// Zig's translate-c cannot materialise a function pointer at that address.
fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null);
}

fn bindOptText(stmt: *c.sqlite3_stmt, index: c_int, text: ?[]const u8) void {
    if (text) |value| bindText(stmt, index, value);
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: ?i64) void {
    if (value) |v| _ = c.sqlite3_bind_int64(stmt, index, v);
}
