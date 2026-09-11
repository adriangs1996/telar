//! SQLite storage owned by the history worker.

const std = @import("std");
const ColumnMigration = @import("ColumnMigration.zig");
const model = @import("../model.zig");
const CommandFinishedType = @import("../CommandFinished.zig");
const TabLocationType = @import("telar-core").TabLocation;
const LocationColumns = @import("LocationColumns.zig");
const raw_module = @import("telar-core").raw;
const EntryType = @import("../Entry.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const max_history_provider_bytes_module = @import("telar-core").max_history_provider_bytes;
const pane_module = @import("telar-core").pane;
const StatsQueryType = @import("../StatsQuery.zig");
const Store = @import("Store.zig");
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const LaunchAttemptType = @import("../LaunchAttempt.zig");
const SessionStartedType = @import("../SessionStarted.zig");
const SessionTitleType = @import("../SessionTitle.zig");
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const QueryType = @import("../Query.zig");
const QueryOriginType = @import("../QueryOrigin.zig");
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const HistoryOriginType = @import("telar-core").HistoryOrigin;
const PruneType = @import("../Prune.zig");

pub const entry_columns = "id, pane_id, started_at_ms, duration_ns, exit_code, status, command, cwd, workspace_path, author, origin, provider, command_truncated";

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

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
pub fn enableCommandSearchIndex(db: *c.sqlite3) bool {
    if (!(tableExists(db, "command_fts") catch return false)) {
        if (c.sqlite3_exec(
            db,
            "CREATE VIRTUAL TABLE command_fts USING fts5(" ++
                "command, content='command', content_rowid='id', " ++
                "tokenize='trigram case_sensitive 0');",
            null,
            null,
            null,
        ) != c.SQLITE_OK) {
            return false;
        }
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
            "END; " ++
            "CREATE TRIGGER IF NOT EXISTS command_fts_update AFTER UPDATE OF command ON command BEGIN " ++
            "INSERT INTO command_fts(command_fts, rowid, command) VALUES ('delete', old.id, old.command); " ++
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
pub fn ftsQuote(text: []const u8, buffer: []u8) []const u8 {
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

pub fn queryCharacters(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn ensureColumn(db: *c.sqlite3, migration: ColumnMigration) !void {
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

pub fn prepare(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        return error.HistoryPrepareFailed;
    }
    return stmt orelse error.HistoryPrepareFailed;
}

pub fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.HistoryWriteFailed;
    }
}

pub fn reset(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
}

pub fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null);
}

pub fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, value: *const model.SessionId) void {
    _ = c.sqlite3_bind_blob(stmt, index, value, value.len, null);
}

pub fn bindCommandSource(stmt: *c.sqlite3_stmt, value: *const CommandFinishedType) void {
    _ = c.sqlite3_bind_int(stmt, 16, @intFromEnum(value.origin));
    if (value.provider.len == 0) {
        _ = c.sqlite3_bind_null(stmt, 17);
    } else {
        bindText(stmt, 17, value.provider);
    }
    if (value.tool_call_id.len == 0) {
        _ = c.sqlite3_bind_null(stmt, 18);
    } else {
        bindText(stmt, 18, value.tool_call_id);
    }
}

pub fn locationColumns(location: TabLocationType) LocationColumns {
    return switch (location.workspace) {
        .workspace => |id| .{ .kind = 0, .id = raw_module(id) },
        .worktree => |id| .{ .kind = 1, .id = raw_module(id) },
    };
}

pub fn readEntry(gpa: std.mem.Allocator, stmt: *c.sqlite3_stmt) !EntryType {
    const command = try columnText(gpa, stmt, 6);
    errdefer gpa.free(command);
    const cwd = try columnText(gpa, stmt, 7);
    errdefer gpa.free(cwd);
    const workspace_path = try columnText(gpa, stmt, 8);
    errdefer gpa.free(workspace_path);
    const provider = try columnText(gpa, stmt, 11);
    errdefer gpa.free(provider);
    const raw_history_id = c.sqlite3_column_int64(stmt, 0);
    const raw_pane = c.sqlite3_column_int64(stmt, 1);
    if (raw_history_id <= 0 or raw_pane <= 0) {
        return error.InvalidHistoryId;
    }
    if (command.len > max_history_command_bytes_module or
        cwd.len > max_cwd_bytes_module or
        workspace_path.len > max_cwd_bytes_module or
        provider.len > max_history_provider_bytes_module)
    {
        return error.InvalidHistoryText;
    }
    const raw_pane_id: u64 = @intCast(raw_pane);
    return .{
        .id = @intCast(raw_history_id),
        .pane_id = try pane_module(raw_pane_id),
        .started_at_ms = c.sqlite3_column_int64(stmt, 2),
        .duration_ns = c.sqlite3_column_int64(stmt, 3),
        .exit_code = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL)
            null
        else
            c.sqlite3_column_int(stmt, 4),
        .status = switch (c.sqlite3_column_int(stmt, 5)) {
            0 => .completed,
            1 => .interrupted,
            2 => .running,
            else => return error.InvalidHistoryStatus,
        },
        .author = switch (c.sqlite3_column_int(stmt, 9)) {
            0 => .human,
            1 => .agent,
            else => return error.InvalidHistoryAuthor,
        },
        .origin = switch (c.sqlite3_column_int(stmt, 10)) {
            0 => .pane,
            1 => .hook,
            2 => .plugin,
            else => return error.InvalidHistoryOrigin,
        },
        .command = command,
        .command_truncated = c.sqlite3_column_int(stmt, 12) != 0,
        .cwd = cwd,
        .workspace_path = workspace_path,
        .provider = provider,
    };
}

/// Borrows the row's command text for hashing/scoring; valid only until the
/// next step or reset.
pub fn columnSlice(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

pub fn commandHash(stmt: *c.sqlite3_stmt) u64 {
    return std.hash.Wyhash.hash(0x74656c6172, columnSlice(stmt, 6));
}

pub fn appendStatsFilters(sql: *std.Io.Writer, request: *const StatsQueryType) !void {
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

pub fn bindStatsFilters(stmt: *c.sqlite3_stmt, request: *const StatsQueryType) void {
    var parameter: c_int = 1;
    if (request.since_ms != 0) {
        _ = c.sqlite3_bind_int64(stmt, parameter, request.since_ms);
        parameter += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => bindText(stmt, parameter, request.scopeSlice()),
        .pane => _ = c.sqlite3_bind_int64(
            stmt,
            parameter,
            @intCast(raw_module(request.pane_id)),
        ),
    }
}

pub fn columnText(gpa: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    if (len == 0) {
        return gpa.alloc(u8, 0);
    }
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
    const pane_id = try pane_module(7);
    const location: TabLocationType = .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(2),
    };
    const attempt: LaunchAttemptType = .{
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

    const session: SessionStartedType = .{
        .id = session_id,
        .pane_id = pane_id,
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);
    const session_title = try SessionTitleType.init(.{
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
        @as(c_int, @intFromEnum(AgentTitleSourceType.generated)),
        c.sqlite3_column_int(title_stmt, 1),
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(AgentTitleStateType.ready)),
        c.sqlite3_column_int(title_stmt, 2),
    );

    const successful: CommandFinishedType = .{
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
    _ = try store.insertCommand(&successful);
    var failed = successful;
    failed.sequence = 2;
    failed.started_at_ms = 3_000;
    failed.exit_code = 2;
    failed.command = @constCast("git commit");
    _ = try store.insertCommand(&failed);
    try store.finishSession(.{ .id = session_id, .finished_at_ms = 4_000 });

    const tab_stmt = try prepare(store.db, "SELECT tab_id FROM command WHERE sequence = 1;");
    defer _ = c.sqlite3_finalize(tab_stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(tab_stmt));
    try std.testing.expectEqual(@as(c_longlong, 2), c.sqlite3_column_int64(tab_stmt, 0));

    const request = try QueryType.init(.{
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
    const indexed = try QueryType.init(.{
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
    const short = try QueryType.init(.{
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
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: SessionStartedType = .{
        .id = @splat(9),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    var base: CommandFinishedType = .{
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
    _ = try store.insertCommand(&base);
    base.sequence = 2;
    base.author = .agent;
    base.command = @constCast("zig build test");
    _ = try store.insertCommand(&base);

    const origin: QueryOriginType = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const humans = try store.query(std.testing.allocator, &(try QueryType.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .author = .human,
    })));
    defer humans.deinit();
    try std.testing.expectEqual(@as(usize, 1), humans.entries.len);
    try std.testing.expectEqualStrings("git status", humans.entries[0].command);
    try std.testing.expectEqual(HistoryAuthorType.human, humans.entries[0].author);

    const agents = try store.query(std.testing.allocator, &(try QueryType.init(.{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .author = .agent,
    })));
    defer agents.deinit();
    try std.testing.expectEqual(@as(usize, 1), agents.entries.len);
    try std.testing.expectEqualStrings("zig build test", agents.entries[0].command);

    const all = try store.query(std.testing.allocator, &(try QueryType.init(.{
        .request_id = @enumFromInt(3),
        .origin = origin,
    })));
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.entries.len);
}

test "agent command synthesis persists provenance and deduplicates tool calls" {
    var store = try Store.open(":memory:");
    defer store.close();
    var value: CommandFinishedType = .{
        .session_id = @splat(0x44),
        .pane_id = @enumFromInt(9),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(3) }, .tab_id = @enumFromInt(5) },
        .sequence = 1,
        .started_at_ms = 100,
        .duration_ns = 0,
        .exit_code = null,
        .status = .running,
        .author = .agent,
        .origin = .hook,
        .cols = 80,
        .rows = 24,
        .command = @constCast("zig build test"),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .provider = @constCast("codex"),
        .tool_call_id = @constCast("call-7"),
        .command_truncated = false,
        .output = @constCast(""),
        .output_truncated = false,
        .output_observed = 0,
    };

    try store.ensureCommandSession(&value);
    try std.testing.expect(try store.insertCommand(&value));
    var plugin = value;
    plugin.sequence = 2;
    plugin.status = .completed;
    plugin.origin = .plugin;
    plugin.provider = @constCast("tap");
    try std.testing.expect(!try store.insertCommand(&plugin));

    value.sequence = 3;
    value.started_at_ms = 250;
    value.exit_code = 7;
    value.status = .completed;
    value.command = @constCast("zig build test --summary all");
    try std.testing.expect(try store.finishAgentCommand(&value));
    plugin.sequence = 4;
    try std.testing.expect(!try store.insertCommand(&plugin));

    const session_count = try prepare(store.db, "SELECT count(*) FROM session;");
    defer _ = c.sqlite3_finalize(session_count);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(session_count));
    try std.testing.expectEqual(@as(c_longlong, 1), c.sqlite3_column_int64(session_count, 0));

    const query = try QueryType.init(.{
        .request_id = @enumFromInt(1),
        .origin = .{ .client = .{ .id = 1, .generation = 1 }, .close_after_reply = false },
        .author = .agent,
    });
    const result = try store.query(std.testing.allocator, &query);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(HistoryOriginType.hook, result.entries[0].origin);
    try std.testing.expectEqualStrings("codex", result.entries[0].provider);
    try std.testing.expectEqualStrings("zig build test --summary all", result.entries[0].command);
    try std.testing.expectEqual(model.CommandStatus.completed, result.entries[0].status);
    try std.testing.expectEqual(@as(i64, 150 * std.time.ns_per_ms), result.entries[0].duration_ns);
    try std.testing.expectEqual(@as(?i32, 7), result.entries[0].exit_code);
}

test "opening a version four database migrates command provenance to version five" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/history.db", .{directory_buffer[0..directory_len]});
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    const opened = db.?;
    const legacy =
        "CREATE TABLE history_schema(version INTEGER NOT NULL); INSERT INTO history_schema VALUES(4);" ++
        "CREATE TABLE session(id BLOB PRIMARY KEY, pane_id INTEGER NOT NULL, location_kind INTEGER NOT NULL, location_id INTEGER NOT NULL, tab_id INTEGER NOT NULL, workspace_path TEXT NOT NULL, shell TEXT NOT NULL, started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER, title TEXT, title_source INTEGER, title_state INTEGER);" ++
        "CREATE TABLE command(id INTEGER PRIMARY KEY, session_id BLOB NOT NULL REFERENCES session(id), pane_id INTEGER NOT NULL, location_kind INTEGER NOT NULL, location_id INTEGER NOT NULL, tab_id INTEGER NOT NULL, sequence INTEGER NOT NULL, command TEXT NOT NULL, command_truncated INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, workspace_path TEXT NOT NULL, started_at_ms INTEGER NOT NULL, duration_ns INTEGER NOT NULL, exit_code INTEGER, status INTEGER NOT NULL, author INTEGER NOT NULL DEFAULT 0, UNIQUE(session_id, sequence));";
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(opened, legacy, null, null, null));
    _ = c.sqlite3_close(opened);

    var store = try Store.open(path);
    defer store.close();
    const version = try prepare(store.db, "SELECT version FROM history_schema;");
    defer _ = c.sqlite3_finalize(version);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(version));
    try std.testing.expectEqual(@as(c_int, 5), c.sqlite3_column_int(version, 0));
    const columns = try prepare(store.db, "SELECT origin, provider, tool_call_id FROM command LIMIT 0;");
    defer _ = c.sqlite3_finalize(columns);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_DONE), c.sqlite3_step(columns));
}

test "delete and prune remove rows and keep the FTS index consistent" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: SessionStartedType = .{
        .id = @splat(4),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    var value: CommandFinishedType = .{
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
    _ = try store.insertCommand(&value);
    value.sequence = 2;
    value.started_at_ms = 9_000;
    value.exit_code = 0;
    value.command = @constCast("git status");
    _ = try store.insertCommand(&value);

    const origin: QueryOriginType = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const found = try store.query(std.testing.allocator, &(try QueryType.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .text = "unique-needle",
    })));
    const first_id = found.entries[0].id;
    found.deinit();

    try std.testing.expectEqual(@as(u64, 1), try store.deleteCommand(first_id));
    try std.testing.expectEqual(@as(u64, 0), try store.deleteCommand(first_id));
    const gone = try store.query(std.testing.allocator, &(try QueryType.init(.{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .text = "unique-needle",
    })));
    defer gone.deinit();
    try std.testing.expectEqual(@as(usize, 0), gone.entries.len);

    const pruned = try store.prune(&(try PruneType.init(.{
        .request_id = @enumFromInt(3),
        .origin = origin,
        .before_ms = 10_000,
    })));
    try std.testing.expectEqual(@as(u64, 1), pruned);
}

test "command output rows round trip through the store" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: SessionStartedType = .{
        .id = @splat(6),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    const value: CommandFinishedType = .{
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
    _ = try store.insertCommand(&value);
    try store.insertCommandOutput(&value);

    const origin: QueryOriginType = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const found = try store.query(std.testing.allocator, &(try QueryType.init(.{
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

test "fuzzy matching ranks subsequences and collapses duplicates" {
    var store = try Store.open(":memory:");
    defer store.close();
    const location: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const session: SessionStartedType = .{
        .id = @splat(8),
        .pane_id = @enumFromInt(1),
        .location = location,
        .started_at_ms = 1_000,
        .workspace_path = @constCast("/work"),
        .shell = @constCast("/bin/zsh"),
    };
    try store.startSession(&session);

    var value: CommandFinishedType = .{
        .session_id = session.id,
        .pane_id = session.pane_id,
        .location = location,
        .sequence = 0,
        .started_at_ms = 0,
        .duration_ns = 1,
        .exit_code = 0,
        .status = .completed,
        .author = .human,
        .cols = 80,
        .rows = 24,
        .command = @constCast(""),
        .cwd = @constCast("/work"),
        .workspace_path = @constCast("/work"),
        .command_truncated = false,
        .output = @constCast(""),
        .output_truncated = false,
        .output_observed = 0,
    };
    const commands = [_][]const u8{ "zig build test", "zig build test", "git status", "zebra-tail", "ls" };
    for (commands, 0..) |command, index| {
        value.sequence = index + 1;
        value.started_at_ms = @intCast((index + 1) * 1_000);
        value.command = @constCast(command);
        _ = try store.insertCommand(&value);
    }

    const origin: QueryOriginType = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    var query_value = try QueryType.init(.{
        .request_id = @enumFromInt(1),
        .origin = origin,
        .text = "zbt",
        .match = .fuzzy,
        .distinct = true,
    });
    const fuzzy = try store.query(std.testing.allocator, &query_value);
    defer fuzzy.deinit();
    try std.testing.expectEqual(@as(usize, 2), fuzzy.entries.len);
    // Tighter subsequence spans rank higher: z·b·t sits in 7 bytes here.
    try std.testing.expectEqualStrings("zebra-tail", fuzzy.entries[0].command);
    try std.testing.expectEqualStrings("zig build test", fuzzy.entries[1].command);

    var distinct_query = try QueryType.init(.{
        .request_id = @enumFromInt(2),
        .origin = origin,
        .distinct = true,
    });
    const collapsed = try store.query(std.testing.allocator, &distinct_query);
    defer collapsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), collapsed.entries.len);
    try std.testing.expectEqualStrings("ls", collapsed.entries[0].command);

    for (0..205) |index| {
        value.sequence = 100 + index;
        value.started_at_ms = @intCast(10000 + index);
        value.command = @constCast("zig build test");
        _ = try store.insertCommand(&value);
    }

    var page_query = try QueryType.init(.{ .request_id = @enumFromInt(3), .origin = origin, .text = "zig", .match = .fuzzy, .limit = 100 });
    const first = try store.query(std.testing.allocator, &page_query);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 100), first.entries.len);
    try std.testing.expect(first.has_more);

    value.sequence = 999;
    value.started_at_ms = 999999;
    _ = try store.insertCommand(&value);
    page_query.snapshot_id = first.snapshot_id;
    page_query.offset = 100;
    const second = try store.query(std.testing.allocator, &page_query);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 100), second.entries.len);
    try std.testing.expect(second.has_more);
    for (first.entries) |left| {
        for (second.entries) |right| {
            try std.testing.expect(left.id != right.id);
        }
    }

    page_query.offset = 200;
    const third = try store.query(std.testing.allocator, &page_query);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 7), third.entries.len);
    try std.testing.expect(!third.has_more);
    page_query.match = .fts;
    const fts_page = try store.query(std.testing.allocator, &page_query);
    defer fts_page.deinit();
    try std.testing.expectEqual(@as(usize, 7), fts_page.entries.len);
    try std.testing.expect(!fts_page.has_more);

    const exact_query = try QueryType.init(.{ .request_id = @enumFromInt(4), .origin = origin, .entry_id = second.entries[0].id, .limit = 1 });
    const exact = try store.query(std.testing.allocator, &exact_query);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, 1), exact.entries.len);
    try std.testing.expectEqual(second.entries[0].id, exact.entries[0].id);
}

pub fn appendQueryFilters(sql: *std.Io.Writer, request: *const QueryType) !void {
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

pub fn bindQueryFilters(stmt: *c.sqlite3_stmt, parameter: *c_int, request: *const QueryType) void {
    if (request.author != .all) {
        const author: HistoryAuthorType = if (request.author == .human) .human else .agent;
        _ = c.sqlite3_bind_int(stmt, parameter.*, @intFromEnum(author));
        parameter.* += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => {
            bindText(stmt, parameter.*, request.scopeSlice());
            parameter.* += 1;
        },
        .pane => {
            _ = c.sqlite3_bind_int64(
                stmt,
                parameter.*,
                @intCast(raw_module(request.pane_id)),
            );
            parameter.* += 1;
        },
    }
}
