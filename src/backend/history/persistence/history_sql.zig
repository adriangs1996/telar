//! The history database: its schema, statements and row mapping.

const core = @import("telar-core");
const std = @import("std");
const sqlite = @import("sqlite");
const CommandFinished = @import("../CommandFinished.zig");
const Entry = @import("../Entry.zig");
const StatsQuery = @import("../StatsQuery.zig");
const Query = @import("../Query.zig");

pub const entry_columns = "id, pane_id, started_at_ms, duration_ns, exit_code, status, command, cwd, workspace_path, author, origin, provider, command_truncated";

pub const database_schema =
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
    \\  author            INTEGER NOT NULL DEFAULT 0,
    \\  origin            INTEGER NOT NULL DEFAULT 0,
    \\  provider          TEXT,
    \\  tool_call_id      TEXT,
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

pub const insert_session_sql =
    \\INSERT INTO session
    \\  (id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
;

pub const import_session_sql =
    \\INSERT OR IGNORE INTO session
    \\  (id, pane_id, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
;

pub const import_command_sql =
    \\INSERT OR IGNORE INTO command
    \\  (session_id, pane_id, location_kind, location_id, tab_id, sequence, command,
    \\   command_truncated, cwd, workspace_path, started_at_ms, duration_ns,
    \\   exit_code, status, author, origin, provider, tool_call_id)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18);
;

pub const delete_command_sql =
    \\DELETE FROM command WHERE id = ?1;
;

pub const insert_command_output_sql =
    \\INSERT INTO command_output (command_id, content, truncated, observed_bytes)
    \\VALUES (last_insert_rowid(), ?1, ?2, ?3);
;

pub const finish_agent_command_sql =
    \\UPDATE command SET
    \\  command = ?1, command_truncated = ?2, cwd = ?3, workspace_path = ?4,
    \\  duration_ns = CASE
    \\    WHEN ?5 <= started_at_ms THEN 0
    \\    WHEN ?5 - started_at_ms > 9223372036854 THEN 9223372036854775807
    \\    ELSE (?5 - started_at_ms) * 1000000
    \\  END,
    \\  exit_code = ?6, status = ?7, author = ?8, origin = ?9, provider = ?10
    \\WHERE session_id = ?11 AND tool_call_id = ?12;
;

pub const read_command_output_sql =
    \\SELECT content, truncated, observed_bytes FROM command_output WHERE command_id = ?1;
;

pub const insert_launch_attempt_sql =
    \\INSERT INTO launch_attempt
    \\  (pane_id, pane_generation, location_kind, location_id, tab_id,
    \\   workspace_path, shell, started_at_ms, failed_at_ms, phase, cause)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
;

pub const finish_session_sql =
    \\UPDATE session SET finished_at_ms = ?2 WHERE id = ?1 AND finished_at_ms IS NULL;
;

pub const set_session_title_sql =
    \\UPDATE session
    \\SET title = ?2, title_source = ?3, title_state = ?4
    \\WHERE id = ?1;
;

pub const insert_command_sql =
    \\INSERT INTO command
    \\  (session_id, pane_id, location_kind, location_id, tab_id, sequence, command,
    \\   command_truncated, cwd, workspace_path, started_at_ms, duration_ns,
    \\   exit_code, status, author, origin, provider, tool_call_id)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
    \\ON CONFLICT(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL DO NOTHING;
;

/// Best effort: without FTS5 or the trigram tokenizer (SQLite < 3.34) the
/// query path falls back to the `instr` scan; history stays functional.
pub fn enableCommandSearchIndex(db: *sqlite.c.sqlite3) bool {
    if (!(sqlite.tableExists(db, "command_fts") catch return false)) {
        if (sqlite.c.sqlite3_exec(
            db,
            "CREATE VIRTUAL TABLE command_fts USING fts5(" ++
                "command, content='command', content_rowid='id', " ++
                "tokenize='trigram case_sensitive 0');",
            null,
            null,
            null,
        ) != sqlite.c.SQLITE_OK) {
            return false;
        }
        // Backfill so history written before this index existed is found too.
        if (sqlite.c.sqlite3_exec(
            db,
            "INSERT INTO command_fts(command_fts) VALUES('rebuild');",
            null,
            null,
            null,
        ) != sqlite.c.SQLITE_OK) {
            _ = sqlite.c.sqlite3_exec(db, "DROP TABLE command_fts;", null, null, null);
            return false;
        }
    }
    return sqlite.c.sqlite3_exec(
        db,
        "CREATE TRIGGER IF NOT EXISTS command_fts_insert AFTER INSERT ON command BEGIN " ++
            "INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command); " ++
            "END; " ++
            "CREATE TRIGGER IF NOT EXISTS command_fts_delete AFTER DELETE ON command BEGIN " ++
            "INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command); " ++
            "END; " ++
            "CREATE TRIGGER IF NOT EXISTS command_fts_update AFTER UPDATE OF command ON command BEGIN " ++
            "INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command); " ++
            "INSERT INTO command_fts(rowid, command) VALUES (new.id, new.command); " ++
            "END;",
        null,
        null,
        null,
    ) == sqlite.c.SQLITE_OK;
}

pub fn queryCharacters(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn bindCommandSource(stmt: *sqlite.c.sqlite3_stmt, value: *const CommandFinished) void {
    _ = sqlite.c.sqlite3_bind_int(stmt, 16, @intFromEnum(value.origin));
    if (value.provider.len == 0) {
        _ = sqlite.c.sqlite3_bind_null(stmt, 17);
    } else {
        sqlite.bindText(stmt, 17, value.provider);
    }
    if (value.tool_call_id.len == 0) {
        _ = sqlite.c.sqlite3_bind_null(stmt, 18);
    } else {
        sqlite.bindText(stmt, 18, value.tool_call_id);
    }
}

pub fn locationColumns(location: core.TabLocation) LocationColumns {
    return switch (location.workspace) {
        .workspace => |id| .{ .kind = 0, .id = core.raw(id) },
        .worktree => |id| .{ .kind = 1, .id = core.raw(id) },
    };
}

pub fn readEntry(gpa: std.mem.Allocator, stmt: *sqlite.c.sqlite3_stmt) !Entry {
    const command = try sqlite.columnText(gpa, stmt, 6);
    errdefer gpa.free(command);
    const cwd = try sqlite.columnText(gpa, stmt, 7);
    errdefer gpa.free(cwd);
    const workspace_path = try sqlite.columnText(gpa, stmt, 8);
    errdefer gpa.free(workspace_path);
    const provider = try sqlite.columnText(gpa, stmt, 11);
    errdefer gpa.free(provider);
    const raw_history_id = sqlite.c.sqlite3_column_int64(stmt, 0);
    const raw_pane = sqlite.c.sqlite3_column_int64(stmt, 1);
    if (raw_history_id <= 0 or raw_pane <= 0) {
        return error.InvalidHistoryId;
    }
    if (command.len > core.max_history_command_bytes or
        cwd.len > core.max_cwd_bytes or
        workspace_path.len > core.max_cwd_bytes or
        provider.len > core.max_history_provider_bytes)
    {
        return error.InvalidHistoryText;
    }
    const raw_pane_id: u64 = @intCast(raw_pane);
    return .{
        .id = @intCast(raw_history_id),
        .pane_id = try core.pane(raw_pane_id),
        .started_at_ms = sqlite.c.sqlite3_column_int64(stmt, 2),
        .duration_ns = sqlite.c.sqlite3_column_int64(stmt, 3),
        .exit_code = if (sqlite.c.sqlite3_column_type(stmt, 4) == sqlite.c.SQLITE_NULL)
            null
        else
            sqlite.c.sqlite3_column_int(stmt, 4),
        .status = switch (sqlite.c.sqlite3_column_int(stmt, 5)) {
            0 => .completed,
            1 => .interrupted,
            2 => .running,
            else => return error.InvalidHistoryStatus,
        },
        .author = switch (sqlite.c.sqlite3_column_int(stmt, 9)) {
            0 => .human,
            1 => .agent,
            else => return error.InvalidHistoryAuthor,
        },
        .origin = switch (sqlite.c.sqlite3_column_int(stmt, 10)) {
            0 => .pane,
            1 => .hook,
            2 => .plugin,
            else => return error.InvalidHistoryOrigin,
        },
        .command = command,
        .command_truncated = sqlite.c.sqlite3_column_int(stmt, 12) != 0,
        .cwd = cwd,
        .workspace_path = workspace_path,
        .provider = provider,
    };
}

pub fn commandHash(stmt: *sqlite.c.sqlite3_stmt) u64 {
    return std.hash.Wyhash.hash(0x74656c6172, sqlite.columnSlice(stmt, 6));
}

pub fn appendStatsFilters(sql: *std.Io.Writer, request: *const StatsQuery) !void {
    if (request.since_ms != 0) {
        try sql.writeAll(" AND started_at_ms >= ?");
    }
    switch (request.scope) {
        .global => {},
        .cwd => try sql.writeAll(" AND cwd = ?"),
        .workspace => try sql.writeAll(" AND workspace_path = ?"),
        .pane => try sql.writeAll(" AND pane_id = ?"),
    }
}

pub fn bindStatsFilters(stmt: *sqlite.c.sqlite3_stmt, request: *const StatsQuery) void {
    var parameter: c_int = 1;
    if (request.since_ms != 0) {
        _ = sqlite.c.sqlite3_bind_int64(stmt, parameter, request.since_ms);
        parameter += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => sqlite.bindText(stmt, parameter, request.scopeSlice()),
        .pane => _ = sqlite.c.sqlite3_bind_int64(
            stmt,
            parameter,
            @intCast(core.raw(request.pane_id)),
        ),
    }
}

pub fn appendQueryFilters(sql: *std.Io.Writer, request: *const Query) !void {
    if (request.failed_only) {
        try sql.writeAll(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }
    if (request.author != .all) {
        try sql.writeAll(" AND author = ?");
    }
    switch (request.scope) {
        .global => {},
        .cwd => try sql.writeAll(" AND cwd = ?"),
        .workspace => try sql.writeAll(" AND workspace_path = ?"),
        .pane => try sql.writeAll(" AND pane_id = ?"),
    }
}

pub fn bindQueryFilters(stmt: *sqlite.c.sqlite3_stmt, parameter: *c_int, request: *const Query) void {
    if (request.author != .all) {
        const author: core.HistoryAuthor = if (request.author == .human) .human else .agent;
        _ = sqlite.c.sqlite3_bind_int(stmt, parameter.*, @intFromEnum(author));
        parameter.* += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => {
            sqlite.bindText(stmt, parameter.*, request.scopeSlice());
            parameter.* += 1;
        },
        .pane => {
            _ = sqlite.c.sqlite3_bind_int64(
                stmt,
                parameter.*,
                @intCast(core.raw(request.pane_id)),
            );
            parameter.* += 1;
        },
    }
}

const LocationColumns = struct { kind: c_int, id: u64 };
