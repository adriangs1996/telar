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
    \\UPDATE history_schema SET version = 4 WHERE version < 4;
    \\CREATE TABLE IF NOT EXISTS launch_attempt (
    \\  id              INTEGER PRIMARY KEY,
    \\  pane_id         INTEGER NOT NULL,
    \\  pane_generation INTEGER NOT NULL,
    \\  location_kind   INTEGER NOT NULL,
    \\  location_id     INTEGER NOT NULL,
    \\  tab_id          INTEGER NOT NULL,
    \\  workspace_path  TEXT NOT NULL,
    \\  shell           TEXT NOT NULL,
    \\  started_at_ms   INTEGER NOT NULL,
    \\  failed_at_ms    INTEGER NOT NULL,
    \\  phase           INTEGER NOT NULL,
    \\  cause           TEXT NOT NULL,
    \\  UNIQUE(pane_id, pane_generation)
    \\);
    \\CREATE TABLE IF NOT EXISTS session (
    \\  id             BLOB PRIMARY KEY,
    \\  pane_id        INTEGER NOT NULL,
    \\  location_kind  INTEGER NOT NULL,
    \\  location_id    INTEGER NOT NULL,
    \\  tab_id         INTEGER NOT NULL,
    \\  workspace_path TEXT NOT NULL,
    \\  shell          TEXT NOT NULL,
    \\  started_at_ms  INTEGER NOT NULL,
    \\  finished_at_ms INTEGER,
    \\  title          TEXT,
    \\  title_source   INTEGER,
    \\  title_state    INTEGER
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

const import_session_sql =
    \\INSERT OR IGNORE INTO session
    \\  (id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
;

const import_command_sql =
    \\INSERT OR IGNORE INTO command
    \\  (session_id, pane_id, location_kind, location_id, tab_id, sequence, command,
    \\   command_truncated, cwd, workspace_path, started_at_ms, duration_ns,
    \\   exit_code, status, author)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
;

const delete_command_sql =
    \\DELETE FROM command WHERE id = ?1;
;

const insert_command_output_sql =
    \\INSERT INTO command_output (command_id, content, truncated, observed_bytes)
    \\VALUES (last_insert_rowid(), ?1, ?2, ?3);
;

const read_command_output_sql =
    \\SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1;
;

const insert_launch_attempt_sql =
    \\INSERT INTO launch_attempt
    \\  (pane_id, pane_generation, location_kind, location_id, tab_id,
    \\   workspace_path, shell, started_at_ms, failed_at_ms, phase, cause)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
;

const finish_session_sql =
    \\UPDATE session SET finished_at_ms = ?2 WHERE id = ?1 AND finished_at_ms IS NULL;
;

const set_session_title_sql =
    \\UPDATE session
    \\SET title = ?2, title_source = ?3, title_state = ?4
    \\WHERE id = ?1;
;

const insert_command_sql =
    \\INSERT INTO command
    \\  (session_id, pane_id, location_kind, location_id, tab_id, sequence, command,
    \\   command_truncated, cwd, workspace_path, started_at_ms, duration_ns,
    \\   exit_code, status, author)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
;

pub const Store = struct {
    db: *c.sqlite3,
    insert_launch_attempt: *c.sqlite3_stmt,
    insert_session: *c.sqlite3_stmt,
    finish_session: *c.sqlite3_stmt,
    set_session_title: *c.sqlite3_stmt,
    insert_command: *c.sqlite3_stmt,
    import_session: *c.sqlite3_stmt,
    import_command: *c.sqlite3_stmt,
    delete_command: *c.sqlite3_stmt,
    insert_command_output: *c.sqlite3_stmt,
    read_command_output: *c.sqlite3_stmt,
    fts_available: bool,

    pub fn open(path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        // One worker owns the connection for its whole active lifetime.
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &db, flags, null) != c.SQLITE_OK)
            return error.HistoryOpenFailed;
        const opened = db orelse return error.HistoryOpenFailed;
        errdefer _ = c.sqlite3_close(opened);
        // Callers may select a custom path and bypass the managed-directory
        // bootstrap. Restrict the database at the persistence boundary too.
        if (!std.mem.eql(u8, path, ":memory:") and std.c.chmod(path.ptr, 0o600) != 0)
            return error.HistoryPermissionsFailed;
        _ = c.sqlite3_extended_result_codes(opened, 1);
        if (c.sqlite3_exec(opened, database_schema, null, null, null) != c.SQLITE_OK)
            return error.HistorySchemaFailed;
        try ensureColumn(opened, .{ .table = "session", .column = "tab_id", .alter_sql = "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
        try ensureColumn(opened, .{ .table = "command", .column = "tab_id", .alter_sql = "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
        try ensureColumn(opened, .{ .table = "session", .column = "title", .alter_sql = "ALTER TABLE session ADD COLUMN title TEXT;" });
        try ensureColumn(opened, .{ .table = "session", .column = "title_source", .alter_sql = "ALTER TABLE session ADD COLUMN title_source INTEGER;" });
        try ensureColumn(opened, .{ .table = "session", .column = "title_state", .alter_sql = "ALTER TABLE session ADD COLUMN title_state INTEGER;" });
        try ensureColumn(opened, .{ .table = "command", .column = "author", .alter_sql = "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0;" });
        const fts_available = enableCommandSearchIndex(opened);

        const insert_launch_attempt = try prepare(opened, insert_launch_attempt_sql);
        errdefer _ = c.sqlite3_finalize(insert_launch_attempt);
        const insert_session = try prepare(opened, insert_session_sql);
        errdefer _ = c.sqlite3_finalize(insert_session);
        const finish_session = try prepare(opened, finish_session_sql);
        errdefer _ = c.sqlite3_finalize(finish_session);
        const set_session_title = try prepare(opened, set_session_title_sql);
        errdefer _ = c.sqlite3_finalize(set_session_title);
        const insert_command = try prepare(opened, insert_command_sql);
        errdefer _ = c.sqlite3_finalize(insert_command);
        const import_session = try prepare(opened, import_session_sql);
        errdefer _ = c.sqlite3_finalize(import_session);
        const import_command = try prepare(opened, import_command_sql);
        errdefer _ = c.sqlite3_finalize(import_command);
        const delete_command = try prepare(opened, delete_command_sql);
        errdefer _ = c.sqlite3_finalize(delete_command);
        const insert_command_output = try prepare(opened, insert_command_output_sql);
        errdefer _ = c.sqlite3_finalize(insert_command_output);
        const read_command_output = try prepare(opened, read_command_output_sql);
        errdefer _ = c.sqlite3_finalize(read_command_output);
        return .{
            .db = opened,
            .insert_launch_attempt = insert_launch_attempt,
            .insert_session = insert_session,
            .finish_session = finish_session,
            .set_session_title = set_session_title,
            .insert_command = insert_command,
            .import_session = import_session,
            .import_command = import_command,
            .delete_command = delete_command,
            .insert_command_output = insert_command_output,
            .read_command_output = read_command_output,
            .fts_available = fts_available,
        };
    }

    pub fn close(store: *Store) void {
        _ = c.sqlite3_finalize(store.read_command_output);
        _ = c.sqlite3_finalize(store.insert_command_output);
        _ = c.sqlite3_finalize(store.delete_command);
        _ = c.sqlite3_finalize(store.import_command);
        _ = c.sqlite3_finalize(store.import_session);
        _ = c.sqlite3_finalize(store.insert_command);
        _ = c.sqlite3_finalize(store.set_session_title);
        _ = c.sqlite3_finalize(store.finish_session);
        _ = c.sqlite3_finalize(store.insert_session);
        _ = c.sqlite3_finalize(store.insert_launch_attempt);
        _ = c.sqlite3_close(store.db);
    }

    pub fn insertLaunchAttempt(store: *Store, value: *const model.LaunchAttempt) !void {
        const stmt = store.insert_launch_attempt;
        defer reset(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(model.schema.id.raw(value.pane_id)));
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(value.pane_generation));
        const location = locationColumns(value.location);
        _ = c.sqlite3_bind_int(stmt, 3, location.kind);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
        bindText(stmt, 6, value.workspace_path);
        bindText(stmt, 7, value.shell);
        _ = c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
        _ = c.sqlite3_bind_int64(stmt, 9, value.failed_at_ms);
        _ = c.sqlite3_bind_int(stmt, 10, @intFromEnum(value.phase));
        bindText(stmt, 11, value.cause);
        try stepDone(stmt);
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

    /// Writes the just-inserted command's bounded output tail. Must run
    /// immediately after `insertCommand` on the same connection, because it
    /// keys on `last_insert_rowid()`.
    ///
    /// ```zig
    /// try store.insertCommandOutput(&value);
    /// ```
    pub fn insertCommandOutput(store: *Store, value: *const model.CommandFinished) !void {
        const stmt = store.insert_command_output;
        defer reset(stmt);
        bindText(stmt, 1, value.output);
        _ = c.sqlite3_bind_int(stmt, 2, @intFromBool(value.output_truncated));
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(value.output_observed));
        try stepDone(stmt);
    }

    /// Reads one entry's stored output into an owned result; a missing row
    /// yields an empty result so "no output captured" is not an error.
    ///
    /// ```zig
    /// const result = try store.readCommandOutput(gpa, request);
    /// ```
    pub fn readCommandOutput(store: *Store, gpa: std.mem.Allocator, request: model.Delete) !*model.OutputResult {
        const stmt = store.read_command_output;
        defer reset(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(request.id));

        const result = try gpa.create(model.OutputResult);
        errdefer gpa.destroy(result);
        result.* = .{
            .request_id = request.request_id,
            .origin = request.origin,
            .id = request.id,
            .truncated = false,
            .observed_bytes = 0,
            .content = try gpa.alloc(u8, 0),
            .gpa = gpa,
        };
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                gpa.free(result.content);
                result.content = try gpa.alloc(u8, 0);
                const content = try columnText(gpa, stmt, 0);
                gpa.free(result.content);
                result.content = content;
                result.truncated = c.sqlite3_column_int(stmt, 1) != 0;
                result.observed_bytes = @intCast(c.sqlite3_column_int64(stmt, 2));
            },
            c.SQLITE_DONE => {},
            else => {
                result.deinit();
                return error.HistoryQueryFailed;
            },
        }
        return result;
    }

    /// Idempotent session insert for imports: the deterministic id makes a
    /// re-import reuse the existing session row.
    ///
    /// ```zig
    /// try store.importSession(&session);
    /// ```
    pub fn importSession(store: *Store, value: *const model.SessionStarted) !void {
        const stmt = store.import_session;
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

    /// Idempotent command insert for imports, keyed by the unique
    /// (session id, sequence) pair.
    ///
    /// ```zig
    /// try store.importCommand(&value);
    /// ```
    pub fn importCommand(store: *Store, value: *const model.CommandFinished) !void {
        const stmt = store.import_command;
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
        _ = c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
        try stepDone(stmt);
    }

    pub fn finishSession(store: *Store, value: model.SessionFinished) !void {
        const stmt = store.finish_session;
        defer reset(stmt);
        bindBlob(stmt, 1, &value.id);
        _ = c.sqlite3_bind_int64(stmt, 2, value.finished_at_ms);
        try stepDone(stmt);
    }

    pub fn setSessionTitle(store: *Store, value: *const model.SessionTitle) !void {
        const stmt = store.set_session_title;
        defer reset(stmt);
        bindBlob(stmt, 1, &value.id);
        bindText(stmt, 2, value.titleSlice());
        _ = c.sqlite3_bind_int(stmt, 3, @intFromEnum(value.source));
        _ = c.sqlite3_bind_int(stmt, 4, @intFromEnum(value.state));
        try stepDone(stmt);
        if (c.sqlite3_changes(store.db) != 1) return error.HistorySessionNotFound;
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
        _ = c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
        try stepDone(stmt);
    }

    /// Deletes one exact entry; its output row cascades and the FTS delete
    /// trigger keeps the index consistent.
    ///
    /// ```zig
    /// const removed = try store.deleteCommand(id);
    /// ```
    pub fn deleteCommand(store: *Store, command_id: u64) !u64 {
        const stmt = store.delete_command;
        defer reset(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(command_id));
        try stepDone(stmt);
        return @intCast(c.sqlite3_changes64(store.db));
    }

    /// Deletes every entry matching the bounded prune filters and returns
    /// the removed count.
    ///
    /// ```zig
    /// const removed = try store.prune(&prune);
    /// ```
    pub fn prune(store: *Store, request: *const model.Prune) !u64 {
        var sql_buffer: [1024]u8 = undefined;
        var sql = std.Io.Writer.fixed(&sql_buffer);
        try sql.writeAll("DELETE FROM command WHERE 1=1");
        var match_buffer: [2 * model.max_query_bytes + 2]u8 = undefined;
        const use_index = store.fts_available and queryCharacters(request.matchSlice()) >= 3;
        if (request.match_len != 0) {
            if (use_index)
                try sql.writeAll(
                    " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?)",
                )
            else
                try sql.writeAll(" AND instr(lower(command), lower(?)) > 0");
        }
        if (request.failed_only)
            try sql.writeAll(" AND exit_code IS NOT NULL AND exit_code <> 0");
        if (request.before_ms != 0)
            try sql.writeAll(" AND started_at_ms < ?");
        switch (request.scope) {
            .global => {},
            .cwd => try sql.writeAll(" AND cwd = ?"),
            .workspace => try sql.writeAll(" AND workspace_path = ?"),
            .pane => try sql.writeAll(" AND pane_id = ?"),
        }
        try sql.writeAll(";");

        const stmt = try prepare(store.db, sql.buffered());
        defer _ = c.sqlite3_finalize(stmt);
        var parameter: c_int = 1;
        if (request.match_len != 0) {
            bindText(stmt, parameter, if (use_index)
                ftsQuote(request.matchSlice(), &match_buffer)
            else
                request.matchSlice());
            parameter += 1;
        }
        if (request.before_ms != 0) {
            _ = c.sqlite3_bind_int64(stmt, parameter, request.before_ms);
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
        try stepDone(stmt);
        return @intCast(c.sqlite3_changes64(store.db));
    }

    /// Executes one bounded history query and returns an owned result that the
    /// caller must deinitialize.
    ///
    /// ```zig
    /// const result = try store.query(gpa, &request);
    /// ```
    pub fn query(store: *Store, gpa: std.mem.Allocator, request: *const model.Query) !*model.QueryResult {
        var sql_buffer: [1024]u8 = undefined;
        var sql = std.Io.Writer.fixed(&sql_buffer);
        try sql.writeAll(
            "SELECT id, pane_id, started_at_ms, duration_ns, exit_code, status, " ++
                "command, cwd, workspace_path, author FROM command WHERE 1=1",
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
        if (request.author != .all)
            try sql.writeAll(" AND author = ?");
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
        if (request.author != .all) {
            const author: model.schema.HistoryAuthor = if (request.author == .human) .human else .agent;
            _ = c.sqlite3_bind_int(stmt, parameter, @intFromEnum(author));
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
            "END; " ++
            "CREATE TRIGGER IF NOT EXISTS command_fts_delete AFTER DELETE ON command BEGIN " ++
            "INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command); " ++
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

const ColumnMigration = struct {
    table: []const u8,
    column: []const u8,
    alter_sql: [:0]const u8,
};

fn ensureColumn(db: *c.sqlite3, migration: ColumnMigration) !void {
    var pragma_buffer: [64]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&pragma_buffer, "PRAGMA table_info({s});", .{migration.table});
    const stmt = try prepare(db, pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const pointer = c.sqlite3_column_text(stmt, 1) orelse continue;
            if (std.mem.eql(u8, pointer[0..len], migration.column)) {
                return;
            }
        },
        c.SQLITE_DONE => break,
        else => return error.HistorySchemaFailed,
    };
    if (c.sqlite3_exec(db, migration.alter_sql.ptr, null, null, null) != c.SQLITE_OK) {
        return error.HistorySchemaFailed;
    }
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
        .author = switch (c.sqlite3_column_int(stmt, 9)) {
            0 => .human,
            1 => .agent,
            else => return error.InvalidHistoryAuthor,
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
    const database_stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), database_stat.permissions.toMode() & 0o777);

    const session_id: model.SessionId = .{1} ** 16;
    const pane_id = try model.schema.id.pane(7);
    const location: model.schema.TabLocation = .{
        .workspace = .{ .workspace = try model.schema.id.workspace(3) },
        .tab_id = try model.schema.id.tab(2),
    };
    const attempt: model.LaunchAttempt = .{
        .pane_id = pane_id,
        .pane_generation = 11,
        .location = location,
        .started_at_ms = 500,
        .failed_at_ms = 600,
        .phase = .output_actor,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
        .cause = @constCast("InjectedLaunchFailure"),
    };
    try store.insertLaunchAttempt(&attempt);
    try std.testing.expectError(error.HistoryWriteFailed, store.insertLaunchAttempt(&attempt));

    const attempt_stmt = try prepare(
        store.db,
        "SELECT pane_generation, phase, cause FROM launch_attempt WHERE pane_id = 7;",
    );
    defer _ = c.sqlite3_finalize(attempt_stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(attempt_stmt));
    try std.testing.expectEqual(@as(c_longlong, 11), c.sqlite3_column_int64(attempt_stmt, 0));
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(model.LaunchPhase.output_actor)),
        c.sqlite3_column_int(attempt_stmt, 1),
    );
    const cause_len: usize = @intCast(c.sqlite3_column_bytes(attempt_stmt, 2));
    const cause = c.sqlite3_column_text(attempt_stmt, 2)[0..cause_len];
    try std.testing.expectEqualStrings("InjectedLaunchFailure", cause);

    const empty_session_stmt = try prepare(store.db, "SELECT count(*) FROM session;");
    defer _ = c.sqlite3_finalize(empty_session_stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(empty_session_stmt));
    try std.testing.expectEqual(@as(c_longlong, 0), c.sqlite3_column_int64(empty_session_stmt, 0));

    const session: model.SessionStarted = .{
        .id = session_id,
        .pane_id = pane_id,
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);
    const session_title = try model.SessionTitle.init(.{
        .id = session_id,
        .title = "Improve agent sidebar",
        .source = .generated,
        .state = .ready,
    });
    try store.setSessionTitle(&session_title);
    const title_stmt = try prepare(
        store.db,
        "SELECT title, title_source, title_state FROM session WHERE id = ?1;",
    );
    defer _ = c.sqlite3_finalize(title_stmt);
    bindBlob(title_stmt, 1, &session_id);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(title_stmt));
    const title_len: usize = @intCast(c.sqlite3_column_bytes(title_stmt, 0));
    const title = c.sqlite3_column_text(title_stmt, 0)[0..title_len];
    try std.testing.expectEqualStrings("Improve agent sidebar", title);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(model.schema.AgentTitleSource.generated)),
        c.sqlite3_column_int(title_stmt, 1),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(model.schema.AgentTitleState.ready)),
        c.sqlite3_column_int(title_stmt, 2),
    );

    const successful: model.CommandFinished = .{
        .session_id = session_id,
        .pane_id = pane_id,
        .location = location,
        .sequence = 1,
        .started_at_ms = 2_000,
        .duration_ns = 12_000,
        .exit_code = 0,
        .status = .completed,
        .author = .human,
        .cols = 80,
        .rows = 24,
        .command = @constCast("git status"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
        .output = @constCast(""),
        .output_truncated = false,
        .output_observed = 0,
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

    const request = try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = .{
            .client = .{ .id = 1, .generation = 1 },
            .close_after_reply = false,
        },
        .text = "git",
        .scope = .cwd,
        .scope_value = "/work",
        .failed_only = true,
        .limit = 20,
    });
    const result = try store.query(gpa, &request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("git commit", result.entries[0].command);
    try std.testing.expectEqual(@as(?i32, 2), result.entries[0].exit_code);

    // The bundled SQLite is expected to carry FTS5 trigram; the scan remains
    // only as a fallback for older libraries.
    try std.testing.expect(store.fts_available);

    // Index path: case-insensitive and substring-capable.
    const indexed = try model.Query.init(.{
        .request_id = @enumFromInt(2),
        .origin = .{
            .client = .{ .id = 1, .generation = 1 },
            .close_after_reply = false,
        },
        .text = "IT COM",
    });
    const indexed_result = try store.query(gpa, &indexed);
    defer indexed_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), indexed_result.entries.len);
    try std.testing.expectEqualStrings("git commit", indexed_result.entries[0].command);

    // Below three characters the query takes the scan fallback.
    const short = try model.Query.init(.{
        .request_id = @enumFromInt(3),
        .origin = .{
            .client = .{ .id = 1, .generation = 1 },
            .close_after_reply = false,
        },
        .text = "gi",
    });
    const short_result = try store.query(gpa, &short);
    defer short_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), short_result.entries.len);
}

test "author filters partition query results" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: model.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: model.SessionStarted = .{
        .id = @splat(9),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    var base: model.CommandFinished = .{
        .session_id = session.id,
        .pane_id = session.pane_id,
        .location = location,
        .sequence = 1,
        .started_at_ms = 2_000,
        .duration_ns = 5,
        .exit_code = 0,
        .status = .completed,
        .author = .human,
        .cols = 80,
        .rows = 24,
        .command = @constCast("git status"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
        .output = @constCast(""),
        .output_truncated = false,
        .output_observed = 0,
    };
    try store.insertCommand(&base);
    base.sequence = 2;
    base.author = .agent;
    base.command = @constCast("zig build test");
    try store.insertCommand(&base);

    const origin: model.QueryOrigin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const humans = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .author = .human,
    })));
    defer humans.deinit();
    try std.testing.expectEqual(@as(usize, 1), humans.entries.len);
    try std.testing.expectEqualStrings("git status", humans.entries[0].command);
    try std.testing.expectEqual(model.schema.HistoryAuthor.human, humans.entries[0].author);

    const agents = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .author = .agent,
    })));
    defer agents.deinit();
    try std.testing.expectEqual(@as(usize, 1), agents.entries.len);
    try std.testing.expectEqualStrings("zig build test", agents.entries[0].command);

    const all = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(3),
        .origin = origin,
    })));
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.entries.len);
}

test "delete and prune remove rows and keep the FTS index consistent" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: model.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: model.SessionStarted = .{
        .id = @splat(4),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    var value: model.CommandFinished = .{
        .session_id = session.id,
        .pane_id = session.pane_id,
        .location = location,
        .sequence = 1,
        .started_at_ms = 1_000,
        .duration_ns = 1,
        .exit_code = 1,
        .status = .completed,
        .author = .human,
        .cols = 80,
        .rows = 24,
        .command = @constCast("zig build unique-needle"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
        .output = @constCast(""),
        .output_truncated = false,
        .output_observed = 0,
    };
    try store.insertCommand(&value);
    value.sequence = 2;
    value.started_at_ms = 9_000;
    value.exit_code = 0;
    value.command = @constCast("git status");
    try store.insertCommand(&value);

    const origin: model.QueryOrigin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const found = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .text = "unique-needle",
    })));
    const first_id = found.entries[0].id;
    found.deinit();

    try std.testing.expectEqual(@as(u64, 1), try store.deleteCommand(first_id));
    try std.testing.expectEqual(@as(u64, 0), try store.deleteCommand(first_id));
    const gone = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .text = "unique-needle",
    })));
    defer gone.deinit();
    try std.testing.expectEqual(@as(usize, 0), gone.entries.len);

    const pruned = try store.prune(&(try model.Prune.init(.{
        .request_id = @enumFromInt(3),
        .origin = origin,
        .before_ms = 10_000,
    })));
    try std.testing.expectEqual(@as(u64, 1), pruned);
}

test "command output rows round trip through the store" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: model.schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: model.SessionStarted = .{
        .id = @splat(6),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    const value: model.CommandFinished = .{
        .session_id = session.id,
        .pane_id = session.pane_id,
        .location = location,
        .sequence = 1,
        .started_at_ms = 2_000,
        .duration_ns = 5,
        .exit_code = 1,
        .status = .completed,
        .author = .human,
        .cols = 80,
        .rows = 24,
        .command = @constCast("make"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
        .output = @constCast("error: exit 1\n"),
        .output_truncated = true,
        .output_observed = 9_000,
    };
    try store.insertCommand(&value);
    try store.insertCommandOutput(&value);

    const origin: model.QueryOrigin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const found = try store.query(std.testing.allocator, &(try model.Query.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
    })));
    const command_id = found.entries[0].id;
    found.deinit();

    const output = try store.readCommandOutput(std.testing.allocator, .{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .id = command_id,
    });
    defer output.deinit();
    try std.testing.expectEqualStrings("error: exit 1\n", output.content);
    try std.testing.expect(output.truncated);
    try std.testing.expectEqual(@as(u64, 9_000), output.observed_bytes);

    const missing = try store.readCommandOutput(std.testing.allocator, .{
        .request_id = @enumFromInt(3),
        .origin = origin,
        .id = command_id + 999,
    });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u64, 0), missing.observed_bytes);
    try std.testing.expectEqual(@as(usize, 0), missing.content.len);
}
