//! SQLite storage owned by the history worker.

const std = @import("std");
const model = @import("model.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const database_schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\PRAGMA foreign_keys = ON;
    \\PRAGMA busy_timeout = 2000;
    \\CREATE TABLE IF NOT EXISTS history_schema (
    \\  version INTEGER NOT NULL
    \\);
    \\INSERT INTO history_schema(version)
    \\SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM history_schema);
    \\CREATE TABLE IF NOT EXISTS session (
    \\  id             BLOB PRIMARY KEY,
    \\  pane_id        INTEGER NOT NULL,
    \\  location_kind  INTEGER NOT NULL,
    \\  location_id    INTEGER NOT NULL,
    \\  tab_id         INTEGER NOT NULL,
    \\  workspace_path TEXT NOT NULL,
    \\  shell          TEXT NOT NULL,
    \\  started_at_ms  INTEGER NOT NULL,
    \\  finished_at_ms INTEGER
    \\);
    \\CREATE TABLE IF NOT EXISTS command (
    \\  id                INTEGER PRIMARY KEY,
    \\  session_id        BLOB NOT NULL REFERENCES session(id),
    \\  pane_id           INTEGER NOT NULL,
    \\  location_kind     INTEGER NOT NULL,
    \\  location_id       INTEGER NOT NULL,
    \\  tab_id            INTEGER NOT NULL,
    \\  sequence          INTEGER NOT NULL,
    \\  command           TEXT NOT NULL,
    \\  command_truncated INTEGER NOT NULL DEFAULT 0,
    \\  cwd               TEXT NOT NULL,
    \\  workspace_path    TEXT NOT NULL,
    \\  started_at_ms     INTEGER NOT NULL,
    \\  duration_ns       INTEGER NOT NULL,
    \\  exit_code         INTEGER,
    \\  status            INTEGER NOT NULL,
    \\  UNIQUE(session_id, sequence)
    \\);
    \\CREATE TABLE IF NOT EXISTS command_output (
    \\  command_id     INTEGER PRIMARY KEY REFERENCES command(id) ON DELETE CASCADE,
    \\  content        TEXT NOT NULL,
    \\  truncated      INTEGER NOT NULL,
    \\  observed_bytes INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS command_started_at ON command(started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS command_session_started ON command(session_id, started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS command_cwd_started ON command(cwd, started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS command_workspace_started ON command(workspace_path, started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS command_pane_started ON command(pane_id, started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS command_exit_started ON command(exit_code, started_at_ms DESC);
    \\CREATE INDEX IF NOT EXISTS session_pane_started ON session(pane_id, started_at_ms DESC);
;

const insert_session_sql =
    \\INSERT INTO session
    \\  (id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
;

const finish_session_sql =
    \\UPDATE session SET finished_at_ms = ?2 WHERE id = ?1 AND finished_at_ms IS NULL;
;

const insert_command_sql =
    \\INSERT INTO command
    \\  (session_id, pane_id, location_kind, location_id, tab_id, sequence, command,
    \\   command_truncated, cwd, workspace_path, started_at_ms, duration_ns,
    \\   exit_code, status)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
;

pub const Store = struct {
    db: *c.sqlite3,
    insert_session: *c.sqlite3_stmt,
    finish_session: *c.sqlite3_stmt,
    insert_command: *c.sqlite3_stmt,
    fts_available: bool,

    pub fn open(path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        // One worker owns the connection for its whole active lifetime.
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK)
            return error.HistoryOpenFailed;
        const opened = db orelse return error.HistoryOpenFailed;
        errdefer _ = c.sqlite3_close(opened);
        _ = c.sqlite3_extended_result_codes(opened, 1);
        if (c.sqlite3_exec(opened, database_schema, null, null, null) != c.SQLITE_OK)
            return error.HistorySchemaFailed;
        try ensureTabColumn(opened, "session", "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;");
        try ensureTabColumn(opened, "command", "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;");
        const fts_available = enableCommandSearchIndex(opened);

        const insert_session = try prepare(opened, insert_session_sql);
        errdefer _ = c.sqlite3_finalize(insert_session);
        const finish_session = try prepare(opened, finish_session_sql);
        errdefer _ = c.sqlite3_finalize(finish_session);
        const insert_command = try prepare(opened, insert_command_sql);
        errdefer _ = c.sqlite3_finalize(insert_command);
        return .{
            .db = opened,
            .insert_session = insert_session,
            .finish_session = finish_session,
            .insert_command = insert_command,
            .fts_available = fts_available,
        };
    }

    pub fn close(store: *Store) void {
        _ = c.sqlite3_finalize(store.insert_command);
        _ = c.sqlite3_finalize(store.finish_session);
        _ = c.sqlite3_finalize(store.insert_session);
        _ = c.sqlite3_close(store.db);
    }

    pub fn startSession(store: *Store, value: *const model.SessionStarted) !void {
        const stmt = store.insert_session;
        defer reset(stmt);
        bindBlob(stmt, 1, &value.id);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
        const location = locationColumns(value.location);
        _ = c.sqlite3_bind_int(stmt, 3, location.kind);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
        bindText(stmt, 6, value.workspace_path);
        bindText(stmt, 7, value.shell);
        _ = c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
        try stepDone(stmt);
    }

    pub fn finishSession(store: *Store, value: model.SessionFinished) !void {
        const stmt = store.finish_session;
        defer reset(stmt);
        bindBlob(stmt, 1, &value.id);
        _ = c.sqlite3_bind_int64(stmt, 2, value.finished_at_ms);
        try stepDone(stmt);
    }

    pub fn insertCommand(store: *Store, value: *const model.CommandFinished) !void {
        const stmt = store.insert_command;
        defer reset(stmt);
        bindBlob(stmt, 1, &value.session_id);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
        const location = locationColumns(value.location);
        _ = c.sqlite3_bind_int(stmt, 3, location.kind);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
        _ = c.sqlite3_bind_int64(stmt, 6, @intCast(value.sequence));
        bindText(stmt, 7, value.command);
        _ = c.sqlite3_bind_int(stmt, 8, @intFromBool(value.command_truncated));
        bindText(stmt, 9, value.cwd);
        bindText(stmt, 10, value.workspace_path);
        _ = c.sqlite3_bind_int64(stmt, 11, value.started_at_ms);
        _ = c.sqlite3_bind_int64(stmt, 12, value.duration_ns);
        if (value.exit_code) |exit_code| {
            _ = c.sqlite3_bind_int(stmt, 13, exit_code);
        } else {
            _ = c.sqlite3_bind_null(stmt, 13);
        }
        _ = c.sqlite3_bind_int(stmt, 14, @intFromEnum(value.status));
        try stepDone(stmt);
    }

    pub fn query(
        store: *Store,
        gpa: std.mem.Allocator,
        request: *const model.Query,
    ) !*model.QueryResult {
        var sql_buffer: [1024]u8 = undefined;
        var sql = std.Io.Writer.fixed(&sql_buffer);
        try sql.writeAll(
            "SELECT id, pane_id, started_at_ms, duration_ns, exit_code, status, " ++
                "command, cwd, workspace_path FROM command WHERE 1=1",
        );
        // The trigram index probes instead of scanning the whole table, and
        // is case-insensitive like the fallback. Trigram matching needs at
        // least three characters; shorter queries take the scan.
        var match_buffer: [2 * model.max_query_bytes + 2]u8 = undefined;
        const use_index = store.fts_available and queryCharacters(request.textSlice()) >= 3;
        if (request.text_len != 0) {
            if (use_index)
                try sql.writeAll(
                    " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?)",
                )
            else
                try sql.writeAll(" AND instr(lower(command), lower(?)) > 0");
        }
        if (request.failed_only)
            try sql.writeAll(" AND exit_code IS NOT NULL AND exit_code <> 0");
        switch (request.scope) {
            .global => {},
            .cwd => try sql.writeAll(" AND cwd = ?"),
            .workspace => try sql.writeAll(" AND workspace_path = ?"),
            .pane => try sql.writeAll(" AND pane_id = ?"),
        }
        try sql.writeAll(" ORDER BY started_at_ms DESC, id DESC LIMIT ?;");

        const stmt = try prepare(store.db, sql.buffered());
        defer _ = c.sqlite3_finalize(stmt);
        var parameter: c_int = 1;
        if (request.text_len != 0) {
            bindText(stmt, parameter, if (use_index)
                ftsQuote(request.textSlice(), &match_buffer)
            else
                request.textSlice());
            parameter += 1;
        }
        switch (request.scope) {
            .global => {},
            .cwd, .workspace => {
                bindText(stmt, parameter, request.scopeSlice());
                parameter += 1;
            },
            .pane => {
                _ = c.sqlite3_bind_int64(
                    stmt,
                    parameter,
                    @intCast(model.schema.id.raw(request.pane_id)),
                );
                parameter += 1;
            },
        }
        _ = c.sqlite3_bind_int(stmt, parameter, request.limit);

        var entries: std.ArrayList(model.Entry) = .empty;
        var encoded_bytes: usize = model.encoded_result_header_bytes;
        errdefer {
            for (entries.items) |*entry| entry.deinit(gpa);
            entries.deinit(gpa);
        }
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                var entry = try readEntry(gpa, stmt);
                const entry_bytes = model.encoded_entry_overhead_bytes +
                    entry.command.len + entry.cwd.len + entry.workspace_path.len;
                if (entry_bytes > model.max_result_payload_bytes - encoded_bytes) {
                    entry.deinit(gpa);
                    break;
                }
                encoded_bytes += entry_bytes;
                try entries.append(gpa, entry);
            },
            c.SQLITE_DONE => break,
            else => return error.HistoryQueryFailed,
        };
        const result = try gpa.create(model.QueryResult);
        errdefer gpa.destroy(result);
        result.* = .{
            .request_id = request.request_id,
            .origin = request.origin,
            .entries = try entries.toOwnedSlice(gpa),
            .gpa = gpa,
        };
        return result;
    }
};

/// Best effort: without FTS5 or the trigram tokenizer (SQLite < 3.34) the
/// query path falls back to the `instr` scan; history stays functional.
fn enableCommandSearchIndex(db: *c.sqlite3) bool {
    if (!(tableExists(db, "command_fts") catch return false)) {
        if (c.sqlite3_exec(
            db,
            "CREATE VIRTUAL TABLE command_fts USING fts5(" ++
                "command, content='command', content_rowid='id', " ++
                "tokenize='trigram case_sensitive 0');",
            null,
            null,
            null,
        ) != c.SQLITE_OK) return false;
        // Backfill so history written before this index existed is found too.
        if (c.sqlite3_exec(
            db,
            "INSERT INTO command_fts(command_fts) VALUES('rebuild');",
            null,
            null,
            null,
        ) != c.SQLITE_OK) {
            _ = c.sqlite3_exec(db, "DROP TABLE command_fts;", null, null, null);
            return false;
        }
    }
    return c.sqlite3_exec(
        db,
        "CREATE TRIGGER IF NOT EXISTS command_fts_insert AFTER INSERT ON command BEGIN " ++
            "INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command); " ++
            "END;",
        null,
        null,
        null,
    ) == c.SQLITE_OK;
}

fn tableExists(db: *c.sqlite3, name: []const u8) !bool {
    const stmt = try prepare(
        db,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
    );
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, name);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.HistorySchemaFailed,
    };
}

/// FTS5 MATCH parses operators out of raw text; quoting the whole query (and
/// doubling interior quotes) turns it into one literal phrase.
fn ftsQuote(text: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    buffer[len] = '"';
    len += 1;
    for (text) |byte| {
        if (byte == '"') {
            buffer[len] = '"';
            len += 1;
        }
        buffer[len] = byte;
        len += 1;
    }
    buffer[len] = '"';
    len += 1;
    return buffer[0..len];
}

fn queryCharacters(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn ensureTabColumn(db: *c.sqlite3, table: []const u8, alter_sql: [:0]const u8) !void {
    var pragma_buffer: [64]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&pragma_buffer, "PRAGMA table_info({s});", .{table});
    const stmt = try prepare(db, pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const pointer = c.sqlite3_column_text(stmt, 1) orelse continue;
            if (std.mem.eql(u8, pointer[0..len], "tab_id")) return;
        },
        c.SQLITE_DONE => break,
        else => return error.HistorySchemaFailed,
    };
    if (c.sqlite3_exec(db, alter_sql.ptr, null, null, null) != c.SQLITE_OK)
        return error.HistorySchemaFailed;
}

fn prepare(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK)
        return error.HistoryPrepareFailed;
    return stmt orelse error.HistoryPrepareFailed;
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.HistoryWriteFailed;
}

fn reset(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null);
}

fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, value: *const model.SessionId) void {
    _ = c.sqlite3_bind_blob(stmt, index, value, value.len, null);
}

const LocationColumns = struct { kind: c_int, id: u64 };

fn locationColumns(location: model.schema.TabLocation) LocationColumns {
    return switch (location.workspace) {
        .workspace => |id| .{ .kind = 0, .id = model.schema.id.raw(id) },
        .worktree => |id| .{ .kind = 1, .id = model.schema.id.raw(id) },
    };
}

fn readEntry(gpa: std.mem.Allocator, stmt: *c.sqlite3_stmt) !model.Entry {
    const command = try columnText(gpa, stmt, 6);
    errdefer gpa.free(command);
    const cwd = try columnText(gpa, stmt, 7);
    errdefer gpa.free(cwd);
    const workspace_path = try columnText(gpa, stmt, 8);
    errdefer gpa.free(workspace_path);
    const raw_history_id = c.sqlite3_column_int64(stmt, 0);
    const raw_pane = c.sqlite3_column_int64(stmt, 1);
    if (raw_history_id <= 0 or raw_pane <= 0) return error.InvalidHistoryId;
    if (command.len > model.schema.max_history_command_bytes or
        cwd.len > model.schema.max_cwd_bytes or
        workspace_path.len > model.schema.max_cwd_bytes)
        return error.InvalidHistoryText;
    const raw_pane_id: u64 = @intCast(raw_pane);
    return .{
        .id = @intCast(raw_history_id),
        .pane_id = try model.schema.id.pane(raw_pane_id),
        .started_at_ms = c.sqlite3_column_int64(stmt, 2),
        .duration_ns = c.sqlite3_column_int64(stmt, 3),
        .exit_code = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL)
            null
        else
            c.sqlite3_column_int(stmt, 4),
        .status = switch (c.sqlite3_column_int(stmt, 5)) {
            0 => .completed,
            1 => .interrupted,
            else => return error.InvalidHistoryStatus,
        },
        .command = command,
        .cwd = cwd,
        .workspace_path = workspace_path,
    };
}

fn columnText(gpa: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    if (len == 0) return gpa.alloc(u8, 0);
    const pointer = c.sqlite3_column_text(stmt, column) orelse return error.InvalidHistoryText;
    return gpa.dupe(u8, pointer[0..len]);
}

test "persists sessions and filters command history" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buffer,
        "{s}/history.db",
        .{directory_buffer[0..directory_len]},
    );
    var store = try Store.open(path);
    defer store.close();

    const session_id: model.SessionId = .{1} ** 16;
    const pane_id = try model.schema.id.pane(7);
    const location: model.schema.TabLocation = .{
        .workspace = .{ .workspace = try model.schema.id.workspace(3) },
        .tab_id = try model.schema.id.tab(2),
    };
    const session: model.SessionStarted = .{
        .id = session_id,
        .pane_id = pane_id,
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    const successful: model.CommandFinished = .{
        .session_id = session_id,
        .pane_id = pane_id,
        .location = location,
        .sequence = 1,
        .started_at_ms = 2_000,
        .duration_ns = 12_000,
        .exit_code = 0,
        .status = .completed,
        .cols = 80,
        .rows = 24,
        .command = @constCast("git status"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
    };
    try store.insertCommand(&successful);
    var failed = successful;
    failed.sequence = 2;
    failed.started_at_ms = 3_000;
    failed.exit_code = 2;
    failed.command = @constCast("git commit");
    try store.insertCommand(&failed);
    try store.finishSession(.{ .id = session_id, .finished_at_ms = 4_000 });

    const tab_stmt = try prepare(store.db, "SELECT tab_id FROM command WHERE sequence = 1;");
    defer _ = c.sqlite3_finalize(tab_stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(tab_stmt));
    try std.testing.expectEqual(@as(c_longlong, 2), c.sqlite3_column_int64(tab_stmt, 0));

    const request = try model.Query.init(
        @enumFromInt(1),
        .primary,
        "git",
        .cwd,
        "/work",
        .invalid,
        true,
        20,
    );
    const result = try store.query(gpa, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("git commit", result.entries[0].command);
    try std.testing.expectEqual(@as(?i32, 2), result.entries[0].exit_code);

    // The bundled SQLite is expected to carry FTS5 trigram; the scan remains
    // only as a fallback for older libraries.
    try std.testing.expect(store.fts_available);

    // Index path: case-insensitive and substring-capable.
    const indexed = try model.Query.init(
        @enumFromInt(2),
        .primary,
        "IT COM",
        .global,
        "",
        .invalid,
        false,
        20,
    );
    const indexed_result = try store.query(gpa, &indexed);
    defer indexed_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), indexed_result.entries.len);
    try std.testing.expectEqualStrings("git commit", indexed_result.entries[0].command);

    // Below three characters the query takes the scan fallback.
    const short = try model.Query.init(
        @enumFromInt(3),
        .primary,
        "gi",
        .global,
        "",
        .invalid,
        false,
        20,
    );
    const short_result = try store.query(gpa, &short);
    defer short_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), short_result.entries.len);
}
