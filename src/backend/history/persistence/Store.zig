const Store = @This();
const source_namespace = @import("sqlite.zig");
const std = @import("std");
const model = @import("../model.zig");
const policy = @import("../search_policy.zig");
const Accumulator = @import("../query_result.zig").Accumulator;
db: *source_namespace.c.sqlite3,
insert_launch_attempt: *source_namespace.c.sqlite3_stmt,
insert_session: *source_namespace.c.sqlite3_stmt,
finish_session: *source_namespace.c.sqlite3_stmt,
set_session_title: *source_namespace.c.sqlite3_stmt,
insert_command: *source_namespace.c.sqlite3_stmt,
import_session: *source_namespace.c.sqlite3_stmt,
import_command: *source_namespace.c.sqlite3_stmt,
delete_command: *source_namespace.c.sqlite3_stmt,
insert_command_output: *source_namespace.c.sqlite3_stmt,
finish_agent_command: *source_namespace.c.sqlite3_stmt,
read_command_output: *source_namespace.c.sqlite3_stmt,
fts_available: bool,

pub fn open(path: [:0]const u8) !Store {
    var db: ?*source_namespace.c.sqlite3 = null;
    // One worker owns the connection for its whole active lifetime.
    const flags = source_namespace.c.SQLITE_OPEN_READWRITE | source_namespace.c.SQLITE_OPEN_CREATE | source_namespace.c.SQLITE_OPEN_NOMUTEX;
    if (source_namespace.c.sqlite3_open_v2(path.ptr, &db, flags, null) != source_namespace.c.SQLITE_OK) {
        return error.HistoryOpenFailed;
    }
    const opened = db orelse return error.HistoryOpenFailed;
    errdefer _ = source_namespace.c.sqlite3_close(opened);
    // Callers may select a custom path and bypass the managed-directory
    // bootstrap. Restrict the database at the persistence boundary too.
    if (!std.mem.eql(u8, path, ":memory:") and std.c.chmod(path.ptr, 0o600) != 0) {
        return error.HistoryPermissionsFailed;
    }
    _ = source_namespace.c.sqlite3_extended_result_codes(opened, 1);
    if (source_namespace.c.sqlite3_exec(opened, source_namespace.database_schema, null, null, null) != source_namespace.c.SQLITE_OK) {
        return error.HistorySchemaFailed;
    }
    try source_namespace.ensureColumn(opened, .{ .table = "session", .column = "tab_id", .alter_sql = "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
    try source_namespace.ensureColumn(opened, .{ .table = "command", .column = "tab_id", .alter_sql = "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
    try source_namespace.ensureColumn(opened, .{ .table = "session", .column = "title", .alter_sql = "ALTER TABLE session ADD COLUMN title TEXT;" });
    try source_namespace.ensureColumn(opened, .{ .table = "session", .column = "title_source", .alter_sql = "ALTER TABLE session ADD COLUMN title_source INTEGER;" });
    try source_namespace.ensureColumn(opened, .{ .table = "session", .column = "title_state", .alter_sql = "ALTER TABLE session ADD COLUMN title_state INTEGER;" });
    try source_namespace.ensureColumn(opened, .{ .table = "command", .column = "author", .alter_sql = "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0;" });
    try source_namespace.ensureColumn(opened, .{ .table = "command", .column = "origin", .alter_sql = "ALTER TABLE command ADD COLUMN origin INTEGER NOT NULL DEFAULT 0;" });
    try source_namespace.ensureColumn(opened, .{ .table = "command", .column = "provider", .alter_sql = "ALTER TABLE command ADD COLUMN provider TEXT;" });
    try source_namespace.ensureColumn(opened, .{ .table = "command", .column = "tool_call_id", .alter_sql = "ALTER TABLE command ADD COLUMN tool_call_id TEXT;" });
    if (source_namespace.c.sqlite3_exec(opened, "CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL; UPDATE history_schema SET version = 5 WHERE version < 5;", null, null, null) != source_namespace.c.SQLITE_OK) {
        return error.HistorySchemaFailed;
    }
    const fts_available = source_namespace.enableCommandSearchIndex(opened);

    const insert_launch_attempt = try source_namespace.prepare(opened, source_namespace.insert_launch_attempt_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(insert_launch_attempt);
    const insert_session = try source_namespace.prepare(opened, source_namespace.insert_session_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(insert_session);
    const finish_session = try source_namespace.prepare(opened, source_namespace.finish_session_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(finish_session);
    const set_session_title = try source_namespace.prepare(opened, source_namespace.set_session_title_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(set_session_title);
    const insert_command = try source_namespace.prepare(opened, source_namespace.insert_command_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(insert_command);
    const import_session = try source_namespace.prepare(opened, source_namespace.import_session_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(import_session);
    const import_command = try source_namespace.prepare(opened, source_namespace.import_command_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(import_command);
    const delete_command = try source_namespace.prepare(opened, source_namespace.delete_command_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(delete_command);
    const insert_command_output = try source_namespace.prepare(opened, source_namespace.insert_command_output_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(insert_command_output);
    const finish_agent_command = try source_namespace.prepare(opened, source_namespace.finish_agent_command_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(finish_agent_command);
    const read_command_output = try source_namespace.prepare(opened, source_namespace.read_command_output_sql);
    errdefer _ = source_namespace.c.sqlite3_finalize(read_command_output);
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
        .finish_agent_command = finish_agent_command,
        .read_command_output = read_command_output,
        .fts_available = fts_available,
    };
}

pub fn close(store: *Store) void {
    _ = source_namespace.c.sqlite3_finalize(store.read_command_output);
    _ = source_namespace.c.sqlite3_finalize(store.insert_command_output);
    _ = source_namespace.c.sqlite3_finalize(store.finish_agent_command);
    _ = source_namespace.c.sqlite3_finalize(store.delete_command);
    _ = source_namespace.c.sqlite3_finalize(store.import_command);
    _ = source_namespace.c.sqlite3_finalize(store.import_session);
    _ = source_namespace.c.sqlite3_finalize(store.insert_command);
    _ = source_namespace.c.sqlite3_finalize(store.set_session_title);
    _ = source_namespace.c.sqlite3_finalize(store.finish_session);
    _ = source_namespace.c.sqlite3_finalize(store.insert_session);
    _ = source_namespace.c.sqlite3_finalize(store.insert_launch_attempt);
    _ = source_namespace.c.sqlite3_close(store.db);
}

pub fn insertLaunchAttempt(store: *Store, value: *const model.LaunchAttempt) !void {
    const stmt = store.insert_launch_attempt;
    defer source_namespace.reset(stmt);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 1, @intCast(model.schema.id.raw(value.pane_id)));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(value.pane_generation));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    source_namespace.bindText(stmt, 6, value.workspace_path);
    source_namespace.bindText(stmt, 7, value.shell);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 9, value.failed_at_ms);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 10, @intFromEnum(value.phase));
    source_namespace.bindText(stmt, 11, value.cause);
    try source_namespace.stepDone(stmt);
}

pub fn startSession(store: *Store, value: *const model.SessionStarted) !void {
    const stmt = store.insert_session;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    source_namespace.bindText(stmt, 6, value.workspace_path);
    source_namespace.bindText(stmt, 7, value.shell);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try source_namespace.stepDone(stmt);
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
    defer source_namespace.reset(stmt);
    source_namespace.bindText(stmt, 1, value.output);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 2, @intFromBool(value.output_truncated));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 3, @intCast(value.output_observed));
    try source_namespace.stepDone(stmt);
}

/// Reads one entry's stored output into an owned result; a missing row
/// yields an empty result so "no output captured" is not an error.
///
/// ```zig
/// const result = try store.readCommandOutput(gpa, request);
/// ```
pub fn readCommandOutput(store: *Store, gpa: std.mem.Allocator, request: model.Delete) !*model.OutputResult {
    const stmt = store.read_command_output;
    defer source_namespace.reset(stmt);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 1, @intCast(request.id));

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
    switch (source_namespace.c.sqlite3_step(stmt)) {
        source_namespace.c.SQLITE_ROW => {
            gpa.free(result.content);
            result.content = try gpa.alloc(u8, 0);
            const content = try source_namespace.columnText(gpa, stmt, 0);
            gpa.free(result.content);
            result.content = content;
            result.truncated = source_namespace.c.sqlite3_column_int(stmt, 1) != 0;
            result.observed_bytes = @intCast(source_namespace.c.sqlite3_column_int64(stmt, 2));
        },
        source_namespace.c.SQLITE_DONE => {},
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
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    source_namespace.bindText(stmt, 6, value.workspace_path);
    source_namespace.bindText(stmt, 7, value.shell);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try source_namespace.stepDone(stmt);
}

/// Ensures an agent-originated command has a parent session even when its
/// source reported before normal pane-session persistence completed.
///
/// ```zig
/// try store.ensureCommandSession(command);
/// ```
pub fn ensureCommandSession(store: *Store, value: *const model.CommandFinished) !void {
    const stmt = store.import_session;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.session_id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    source_namespace.bindText(stmt, 6, value.workspace_path);
    source_namespace.bindText(stmt, 7, "");
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try source_namespace.stepDone(stmt);
}

/// Idempotent command insert for imports, keyed by the unique
/// (session id, sequence) pair.
///
/// ```zig
/// try store.importCommand(&value);
/// ```
pub fn importCommand(store: *Store, value: *const model.CommandFinished) !void {
    const stmt = store.import_command;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.session_id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 6, @intCast(value.sequence));
    source_namespace.bindText(stmt, 7, value.command);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 8, @intFromBool(value.command_truncated));
    source_namespace.bindText(stmt, 9, value.cwd);
    source_namespace.bindText(stmt, 10, value.workspace_path);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 11, value.started_at_ms);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 12, value.duration_ns);
    if (value.exit_code) |exit_code| {
        _ = source_namespace.c.sqlite3_bind_int(stmt, 13, exit_code);
    } else {
        _ = source_namespace.c.sqlite3_bind_null(stmt, 13);
    }
    _ = source_namespace.c.sqlite3_bind_int(stmt, 14, @intFromEnum(value.status));
    _ = source_namespace.c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
    source_namespace.bindCommandSource(stmt, value);
    try source_namespace.stepDone(stmt);
}

pub fn finishSession(store: *Store, value: model.SessionFinished) !void {
    const stmt = store.finish_session;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, value.finished_at_ms);
    try source_namespace.stepDone(stmt);
}

pub fn setSessionTitle(store: *Store, value: *const model.SessionTitle) !void {
    const stmt = store.set_session_title;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.id);
    source_namespace.bindText(stmt, 2, value.titleSlice());
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, @intFromEnum(value.source));
    _ = source_namespace.c.sqlite3_bind_int(stmt, 4, @intFromEnum(value.state));
    try source_namespace.stepDone(stmt);
    if (source_namespace.c.sqlite3_changes(store.db) != 1) {
        return error.HistorySessionNotFound;
    }
}

pub fn insertCommand(store: *Store, value: *const model.CommandFinished) !bool {
    const stmt = store.insert_command;
    defer source_namespace.reset(stmt);
    source_namespace.bindBlob(stmt, 1, &value.session_id);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 2, @intCast(model.schema.id.raw(value.pane_id)));
    const location = source_namespace.locationColumns(value.location);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, @intCast(model.schema.id.raw(value.location.tab_id)));
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 6, @intCast(value.sequence));
    source_namespace.bindText(stmt, 7, value.command);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 8, @intFromBool(value.command_truncated));
    source_namespace.bindText(stmt, 9, value.cwd);
    source_namespace.bindText(stmt, 10, value.workspace_path);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 11, value.started_at_ms);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 12, value.duration_ns);
    if (value.exit_code) |exit_code| {
        _ = source_namespace.c.sqlite3_bind_int(stmt, 13, exit_code);
    } else {
        _ = source_namespace.c.sqlite3_bind_null(stmt, 13);
    }
    _ = source_namespace.c.sqlite3_bind_int(stmt, 14, @intFromEnum(value.status));
    _ = source_namespace.c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
    source_namespace.bindCommandSource(stmt, value);
    try source_namespace.stepDone(stmt);
    return source_namespace.c.sqlite3_changes(store.db) == 1;
}

/// Closes a hook-started command without changing its stable row id.
/// Returns false when no matching start was persisted.
///
/// ```zig
/// if (!try store.finishAgentCommand(command)) _ = try store.insertCommand(command);
/// ```
pub fn finishAgentCommand(store: *Store, value: *const model.CommandFinished) !bool {
    if (value.tool_call_id.len == 0) {
        return false;
    }

    const stmt = store.finish_agent_command;
    defer source_namespace.reset(stmt);
    source_namespace.bindText(stmt, 1, value.command);
    _ = source_namespace.c.sqlite3_bind_int(stmt, 2, @intFromBool(value.command_truncated));
    source_namespace.bindText(stmt, 3, value.cwd);
    source_namespace.bindText(stmt, 4, value.workspace_path);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 5, value.started_at_ms);
    if (value.exit_code) |exit_code| {
        _ = source_namespace.c.sqlite3_bind_int(stmt, 6, exit_code);
    } else {
        _ = source_namespace.c.sqlite3_bind_null(stmt, 6);
    }
    _ = source_namespace.c.sqlite3_bind_int(stmt, 7, @intFromEnum(value.status));
    _ = source_namespace.c.sqlite3_bind_int(stmt, 8, @intFromEnum(value.author));
    _ = source_namespace.c.sqlite3_bind_int(stmt, 9, @intFromEnum(value.origin));
    if (value.provider.len == 0) {
        _ = source_namespace.c.sqlite3_bind_null(stmt, 10);
    } else {
        source_namespace.bindText(stmt, 10, value.provider);
    }
    source_namespace.bindBlob(stmt, 11, &value.session_id);
    source_namespace.bindText(stmt, 12, value.tool_call_id);
    try source_namespace.stepDone(stmt);
    return source_namespace.c.sqlite3_changes(store.db) == 1;
}

/// Fuzzy path: scans the newest candidates in scope and keeps the best
/// requested page of subsequence matches. Only IDs and scores are retained
/// while ranking; full entries are allocated for the resulting page.
fn queryFuzzy(store: *Store, gpa: std.mem.Allocator, request: *const model.Query) !*model.QueryResult {
    const max_candidates = policy.FuzzyPage.max_candidates;
    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT " ++ source_namespace.entry_columns ++ " FROM command WHERE id <= ?");
    try source_namespace.appendQueryFilters(&sql, request);
    try sql.writeAll(" ORDER BY started_at_ms DESC, id DESC LIMIT ?;");

    const stmt = try source_namespace.prepare(store.db, sql.buffered());
    defer _ = source_namespace.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    _ = source_namespace.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.snapshot_id));
    parameter += 1;
    source_namespace.bindQueryFilters(stmt, &parameter, request);
    _ = source_namespace.c.sqlite3_bind_int(stmt, parameter, max_candidates);

    var ranking = policy.FuzzyPage.init(request);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);

    while (true) switch (source_namespace.c.sqlite3_step(stmt)) {
        source_namespace.c.SQLITE_ROW => {
            const hash = source_namespace.commandHash(stmt);
            if (request.distinct and seen.contains(hash)) {
                continue;
            }

            if (request.distinct) {
                try seen.put(gpa, hash, {});
            }

            ranking.consider(.{
                .id = source_namespace.c.sqlite3_column_int64(stmt, 0),
                .command = source_namespace.columnSlice(stmt, 6),
            }, request.textSlice());
        },
        source_namespace.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };

    const detail = try source_namespace.prepare(store.db, "SELECT " ++ source_namespace.entry_columns ++ " FROM command WHERE id = ?;");
    defer _ = source_namespace.c.sqlite3_finalize(detail);
    var accumulator: Accumulator = .{ .gpa = gpa, .limit = request.limit };
    defer accumulator.deinit();
    const start = @min(request.offset, ranking.count);
    const end = @min(start + request.limit, ranking.count);
    for (ranking.best[start..end]) |scored| {
        source_namespace.reset(detail);
        _ = source_namespace.c.sqlite3_bind_int64(detail, 1, scored.id);
        if (source_namespace.c.sqlite3_step(detail) != source_namespace.c.SQLITE_ROW) {
            return error.HistoryQueryFailed;
        }

        if (!try accumulator.append(try source_namespace.readEntry(gpa, detail))) {
            break;
        }
    }

    return accumulator.finish(request, start + accumulator.entries.items.len < ranking.count);
}

/// Aggregates totals, distinct commands, and the top command groups in
/// one scope. Grouping folds known multi-word tools (git, docker, ...)
/// to their first two tokens and skips a leading `sudo`, computed over
/// the 400 most frequent full commands.
///
/// ```zig
/// const result = try store.stats(gpa, &query);
/// ```
pub fn stats(store: *Store, gpa: std.mem.Allocator, request: *const model.StatsQuery) !*model.StatsResult {
    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT COUNT(*), COUNT(DISTINCT command) FROM command WHERE 1=1");
    try source_namespace.appendStatsFilters(&sql, request);
    const totals_stmt = try source_namespace.prepare(store.db, sql.buffered());
    var total: u64 = 0;
    var unique: u64 = 0;
    {
        defer _ = source_namespace.c.sqlite3_finalize(totals_stmt);
        source_namespace.bindStatsFilters(totals_stmt, request);
        switch (source_namespace.c.sqlite3_step(totals_stmt)) {
            source_namespace.c.SQLITE_ROW => {
                total = @intCast(source_namespace.c.sqlite3_column_int64(totals_stmt, 0));
                unique = @intCast(source_namespace.c.sqlite3_column_int64(totals_stmt, 1));
            },
            else => return error.HistoryQueryFailed,
        }
    }

    var top_sql_buffer: [1024]u8 = undefined;
    var top_sql = std.Io.Writer.fixed(&top_sql_buffer);
    try top_sql.writeAll("SELECT command, COUNT(*) AS n FROM command WHERE 1=1");
    try source_namespace.appendStatsFilters(&top_sql, request);
    try top_sql.writeAll(" GROUP BY command ORDER BY n DESC LIMIT 400;");
    const stmt = try source_namespace.prepare(store.db, top_sql.buffered());
    defer _ = source_namespace.c.sqlite3_finalize(stmt);
    source_namespace.bindStatsFilters(stmt, request);

    var buckets: std.StringHashMapUnmanaged(u64) = .empty;
    defer {
        var keys = buckets.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        buckets.deinit(gpa);
    }
    while (true) switch (source_namespace.c.sqlite3_step(stmt)) {
        source_namespace.c.SQLITE_ROW => {
            const command = source_namespace.columnSlice(stmt, 0);
            const count: u64 = @intCast(source_namespace.c.sqlite3_column_int64(stmt, 1));
            const key = source_namespace.statsGroupKey(command);
            if (buckets.getPtr(key)) |slot| {
                slot.* += count;
            } else {
                try buckets.put(gpa, try gpa.dupe(u8, key), count);
            }
        },
        source_namespace.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };

    const Top = struct { count: u64, key: []const u8 };
    var best: [model.schema.max_history_stats_top]Top = undefined;
    var best_len: usize = 0;
    var iterator = buckets.iterator();
    while (iterator.next()) |entry| {
        const count = entry.value_ptr.*;
        if (best_len == best.len and count <= best[best_len - 1].count) {
            continue;
        }
        var index = if (best_len == best.len) best_len - 1 else blk: {
            best_len += 1;
            break :blk best_len - 1;
        };
        while (index > 0 and best[index - 1].count < count) : (index -= 1) {
            best[index] = best[index - 1];
        }
        best[index] = .{ .count = count, .key = entry.key_ptr.* };
    }

    const result = try gpa.create(model.StatsResult);
    errdefer gpa.destroy(result);
    const top = try gpa.alloc(model.StatsTop, best_len);
    var copied: usize = 0;
    errdefer {
        for (top[0..copied]) |entry| gpa.free(entry.command);
        gpa.free(top);
    }
    for (best[0..best_len], 0..) |entry, index| {
        top[index] = .{ .count = entry.count, .command = try gpa.dupe(u8, entry.key) };
        copied += 1;
    }
    result.* = .{
        .request_id = request.request_id,
        .origin = request.origin,
        .total = total,
        .unique = unique,
        .top = top,
        .gpa = gpa,
    };
    return result;
}

/// Deletes one exact entry; its output row cascades and the FTS delete
/// trigger keeps the index consistent.
///
/// ```zig
/// const removed = try store.deleteCommand(id);
/// ```
pub fn deleteCommand(store: *Store, command_id: u64) !u64 {
    const stmt = store.delete_command;
    defer source_namespace.reset(stmt);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, 1, @intCast(command_id));
    try source_namespace.stepDone(stmt);
    return @intCast(source_namespace.c.sqlite3_changes64(store.db));
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
    const use_index = store.fts_available and source_namespace.queryCharacters(request.matchSlice()) >= 3;
    if (request.match_len != 0) {
        if (use_index) {
            try sql.writeAll(
                " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?)",
            );
        } else {
            try sql.writeAll(" AND instr(lower(command), lower(?)) > 0");
        }
    }
    if (request.failed_only) {
        try sql.writeAll(" AND exit_code IS NOT NULL AND exit_code <> 0");
    }
    if (request.before_ms != 0) {
        try sql.writeAll(" AND started_at_ms < ?");
    }
    switch (request.scope) {
        .global => {},
        .cwd => try sql.writeAll(" AND cwd = ?"),
        .workspace => try sql.writeAll(" AND workspace_path = ?"),
        .pane => try sql.writeAll(" AND pane_id = ?"),
    }
    try sql.writeAll(";");

    const stmt = try source_namespace.prepare(store.db, sql.buffered());
    defer _ = source_namespace.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    if (request.match_len != 0) {
        source_namespace.bindText(stmt, parameter, if (use_index)
            source_namespace.ftsQuote(request.matchSlice(), &match_buffer)
        else
            request.matchSlice());
        parameter += 1;
    }
    if (request.before_ms != 0) {
        _ = source_namespace.c.sqlite3_bind_int64(stmt, parameter, request.before_ms);
        parameter += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => {
            source_namespace.bindText(stmt, parameter, request.scopeSlice());
            parameter += 1;
        },
        .pane => {
            _ = source_namespace.c.sqlite3_bind_int64(
                stmt,
                parameter,
                @intCast(model.schema.id.raw(request.pane_id)),
            );
            parameter += 1;
        },
    }
    try source_namespace.stepDone(stmt);
    return @intCast(source_namespace.c.sqlite3_changes64(store.db));
}

/// Executes one bounded history query and returns an owned result that the
/// caller must deinitialize.
///
/// ```zig
/// const result = try store.query(gpa, &request);
/// ```
pub fn query(store: *Store, gpa: std.mem.Allocator, original: *const model.Query) !*model.QueryResult {
    var bounded = original.*;
    if (bounded.snapshot_id == 0) {
        const boundary = try source_namespace.prepare(store.db, "SELECT COALESCE(MAX(id), 0) FROM command;");
        defer _ = source_namespace.c.sqlite3_finalize(boundary);
        if (source_namespace.c.sqlite3_step(boundary) != source_namespace.c.SQLITE_ROW) {
            return error.HistoryQueryFailed;
        }

        bounded.snapshot_id = @intCast(source_namespace.c.sqlite3_column_int64(boundary, 0));
    }

    const request = &bounded;
    if (request.match == .fuzzy and request.text_len != 0 and request.entry_id == 0) {
        return store.queryFuzzy(gpa, request);
    }

    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT " ++ source_namespace.entry_columns ++ " FROM command WHERE id <= ?");
    if (request.entry_id != 0) {
        try sql.writeAll(" AND id = ?");
    }
    // The trigram index probes instead of scanning the whole table, and
    // is case-insensitive like the fallback. Trigram matching needs at
    // least three characters; shorter queries take the scan.
    var match_buffer: [2 * model.max_query_bytes + 2]u8 = undefined;
    const use_index = store.fts_available and source_namespace.queryCharacters(request.textSlice()) >= 3;
    if (request.text_len != 0) {
        if (use_index) {
            try sql.writeAll(
                " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?)",
            );
        } else {
            try sql.writeAll(" AND instr(lower(command), lower(?)) > 0");
        }
    }
    try source_namespace.appendQueryFilters(&sql, request);
    try sql.writeAll(" ORDER BY started_at_ms DESC, id DESC LIMIT ? OFFSET ?;");

    const stmt = try source_namespace.prepare(store.db, sql.buffered());
    defer _ = source_namespace.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    _ = source_namespace.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.snapshot_id));
    parameter += 1;
    if (request.entry_id != 0) {
        _ = source_namespace.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.entry_id));
        parameter += 1;
    }
    if (request.text_len != 0) {
        source_namespace.bindText(stmt, parameter, if (use_index)
            source_namespace.ftsQuote(request.textSlice(), &match_buffer)
        else
            request.textSlice());
        parameter += 1;
    }
    source_namespace.bindQueryFilters(stmt, &parameter, request);
    _ = source_namespace.c.sqlite3_bind_int(stmt, parameter, @as(c_int, request.limit) + 1);
    _ = source_namespace.c.sqlite3_bind_int64(stmt, parameter + 1, request.offset);

    var accumulator: Accumulator = .{ .gpa = gpa, .limit = request.limit };
    defer accumulator.deinit();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    while (true) switch (source_namespace.c.sqlite3_step(stmt)) {
        source_namespace.c.SQLITE_ROW => {
            if (request.distinct) {
                if (seen.contains(source_namespace.commandHash(stmt))) {
                    continue;
                }
                try seen.put(gpa, source_namespace.commandHash(stmt), {});
            }

            if (accumulator.entries.items.len == request.limit) {
                accumulator.has_more = true;
                break;
            }

            if (!try accumulator.append(try source_namespace.readEntry(gpa, stmt))) {
                break;
            }
        },
        source_namespace.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };
    return accumulator.finish(request, false);
}
