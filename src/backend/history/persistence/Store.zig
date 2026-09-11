const sqlite = @import("sqlite.zig");
const std = @import("std");
const LaunchAttemptType = @import("../LaunchAttempt.zig");
const raw_module = @import("telar-core").raw;
const SessionStartedType = @import("../SessionStarted.zig");
const CommandFinishedType = @import("../CommandFinished.zig");
const DeleteType = @import("../Delete.zig");
const OutputResultType = @import("../OutputResult.zig");
const SessionFinishedType = @import("../SessionFinished.zig");
const SessionTitleType = @import("../SessionTitle.zig");
const QueryType = @import("../Query.zig");
const QueryResultType = @import("../QueryResult.zig");
const FuzzyPageType = @import("../FuzzyPage.zig");
const Accumulator = @import("../Accumulator.zig");
const StatsQueryType = @import("../StatsQuery.zig");
const StatsResultType = @import("../StatsResult.zig");
const policy = @import("../search_policy.zig");
const max_history_stats_top_module = @import("telar-core").max_history_stats_top;
const StatsTopType = @import("../StatsTop.zig");
const PruneType = @import("../Prune.zig");
const max_history_query_bytes = @import("telar-core").max_history_query_bytes;
const Store = @This();

db: *sqlite.c.sqlite3,
insert_launch_attempt: *sqlite.c.sqlite3_stmt,
insert_session: *sqlite.c.sqlite3_stmt,
finish_session: *sqlite.c.sqlite3_stmt,
set_session_title: *sqlite.c.sqlite3_stmt,
insert_command: *sqlite.c.sqlite3_stmt,
import_session: *sqlite.c.sqlite3_stmt,
import_command: *sqlite.c.sqlite3_stmt,
delete_command: *sqlite.c.sqlite3_stmt,
insert_command_output: *sqlite.c.sqlite3_stmt,
finish_agent_command: *sqlite.c.sqlite3_stmt,
read_command_output: *sqlite.c.sqlite3_stmt,
fts_available: bool,

pub fn open(path: [:0]const u8) !Store {
    var db: ?*sqlite.c.sqlite3 = null;
    // One worker owns the connection for its whole active lifetime.
    const flags = sqlite.c.SQLITE_OPEN_READWRITE | sqlite.c.SQLITE_OPEN_CREATE | sqlite.c.SQLITE_OPEN_NOMUTEX;
    if (sqlite.c.sqlite3_open_v2(path.ptr, &db, flags, null) != sqlite.c.SQLITE_OK) {
        return error.HistoryOpenFailed;
    }
    const opened = db orelse return error.HistoryOpenFailed;
    errdefer _ = sqlite.c.sqlite3_close(opened);
    // Callers may select a custom path and bypass the managed-directory
    // bootstrap. Restrict the database at the persistence boundary too.
    if (!std.mem.eql(u8, path, ":memory:") and std.c.chmod(path.ptr, 0o600) != 0) {
        return error.HistoryPermissionsFailed;
    }
    _ = sqlite.c.sqlite3_extended_result_codes(opened, 1);
    if (sqlite.c.sqlite3_exec(opened, sqlite.database_schema, null, null, null) != sqlite.c.SQLITE_OK) {
        return error.HistorySchemaFailed;
    }
    try sqlite.ensureColumn(opened, .{ .table = "session", .column = "tab_id", .alter_sql = "ALTER TABLE session ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
    try sqlite.ensureColumn(opened, .{ .table = "command", .column = "tab_id", .alter_sql = "ALTER TABLE command ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0;" });
    try sqlite.ensureColumn(opened, .{ .table = "session", .column = "title", .alter_sql = "ALTER TABLE session ADD COLUMN title TEXT;" });
    try sqlite.ensureColumn(opened, .{ .table = "session", .column = "title_source", .alter_sql = "ALTER TABLE session ADD COLUMN title_source INTEGER;" });
    try sqlite.ensureColumn(opened, .{ .table = "session", .column = "title_state", .alter_sql = "ALTER TABLE session ADD COLUMN title_state INTEGER;" });
    try sqlite.ensureColumn(opened, .{ .table = "command", .column = "author", .alter_sql = "ALTER TABLE command ADD COLUMN author INTEGER NOT NULL DEFAULT 0;" });
    try sqlite.ensureColumn(opened, .{ .table = "command", .column = "origin", .alter_sql = "ALTER TABLE command ADD COLUMN origin INTEGER NOT NULL DEFAULT 0;" });
    try sqlite.ensureColumn(opened, .{ .table = "command", .column = "provider", .alter_sql = "ALTER TABLE command ADD COLUMN provider TEXT;" });
    try sqlite.ensureColumn(opened, .{ .table = "command", .column = "tool_call_id", .alter_sql = "ALTER TABLE command ADD COLUMN tool_call_id TEXT;" });
    if (sqlite.c.sqlite3_exec(opened, "CREATE UNIQUE INDEX IF NOT EXISTS command_tool_call ON command(session_id, tool_call_id) WHERE tool_call_id IS NOT NULL; UPDATE history_schema SET version = 5 WHERE version < 5;", null, null, null) != sqlite.c.SQLITE_OK) {
        return error.HistorySchemaFailed;
    }
    const fts_available = sqlite.enableCommandSearchIndex(opened);

    const insert_launch_attempt = try sqlite.prepare(opened, sqlite.insert_launch_attempt_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(insert_launch_attempt);
    const insert_session = try sqlite.prepare(opened, sqlite.insert_session_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(insert_session);
    const finish_session = try sqlite.prepare(opened, sqlite.finish_session_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(finish_session);
    const set_session_title = try sqlite.prepare(opened, sqlite.set_session_title_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(set_session_title);
    const insert_command = try sqlite.prepare(opened, sqlite.insert_command_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(insert_command);
    const import_session = try sqlite.prepare(opened, sqlite.import_session_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(import_session);
    const import_command = try sqlite.prepare(opened, sqlite.import_command_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(import_command);
    const delete_command = try sqlite.prepare(opened, sqlite.delete_command_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(delete_command);
    const insert_command_output = try sqlite.prepare(opened, sqlite.insert_command_output_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(insert_command_output);
    const finish_agent_command = try sqlite.prepare(opened, sqlite.finish_agent_command_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(finish_agent_command);
    const read_command_output = try sqlite.prepare(opened, sqlite.read_command_output_sql);
    errdefer _ = sqlite.c.sqlite3_finalize(read_command_output);
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
    _ = sqlite.c.sqlite3_finalize(store.read_command_output);
    _ = sqlite.c.sqlite3_finalize(store.insert_command_output);
    _ = sqlite.c.sqlite3_finalize(store.finish_agent_command);
    _ = sqlite.c.sqlite3_finalize(store.delete_command);
    _ = sqlite.c.sqlite3_finalize(store.import_command);
    _ = sqlite.c.sqlite3_finalize(store.import_session);
    _ = sqlite.c.sqlite3_finalize(store.insert_command);
    _ = sqlite.c.sqlite3_finalize(store.set_session_title);
    _ = sqlite.c.sqlite3_finalize(store.finish_session);
    _ = sqlite.c.sqlite3_finalize(store.insert_session);
    _ = sqlite.c.sqlite3_finalize(store.insert_launch_attempt);
    _ = sqlite.c.sqlite3_close(store.db);
}

pub fn insertLaunchAttempt(store: *Store, value: *const LaunchAttemptType) !void {
    const stmt = store.insert_launch_attempt;
    defer sqlite.reset(stmt);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 1, @intCast(raw_module(value.pane_id)));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(value.pane_generation));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    sqlite.bindText(stmt, 6, value.workspace_path);
    sqlite.bindText(stmt, 7, value.shell);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 9, value.failed_at_ms);
    _ = sqlite.c.sqlite3_bind_int(stmt, 10, @intFromEnum(value.phase));
    sqlite.bindText(stmt, 11, value.cause);
    try sqlite.stepDone(stmt);
}

pub fn startSession(store: *Store, value: *const SessionStartedType) !void {
    const stmt = store.insert_session;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(raw_module(value.pane_id)));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    sqlite.bindText(stmt, 6, value.workspace_path);
    sqlite.bindText(stmt, 7, value.shell);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try sqlite.stepDone(stmt);
}

/// Writes the just-inserted command's bounded output tail. Must run
/// immediately after `insertCommand` on the same connection, because it
/// keys on `last_insert_rowid()`.
///
/// ```zig
/// try store.insertCommandOutput(&value);
/// ```
pub fn insertCommandOutput(store: *Store, value: *const CommandFinishedType) !void {
    const stmt = store.insert_command_output;
    defer sqlite.reset(stmt);
    sqlite.bindText(stmt, 1, value.output);
    _ = sqlite.c.sqlite3_bind_int(stmt, 2, @intFromBool(value.output_truncated));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 3, @intCast(value.output_observed));
    try sqlite.stepDone(stmt);
}

/// Reads one entry's stored output into an owned result; a missing row
/// yields an empty result so "no output captured" is not an error.
///
/// ```zig
/// const result = try store.readCommandOutput(gpa, request);
/// ```
pub fn readCommandOutput(store: *Store, gpa: std.mem.Allocator, request: DeleteType) !*OutputResultType {
    const stmt = store.read_command_output;
    defer sqlite.reset(stmt);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 1, @intCast(request.id));

    const result = try gpa.create(OutputResultType);
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
    switch (sqlite.c.sqlite3_step(stmt)) {
        sqlite.c.SQLITE_ROW => {
            gpa.free(result.content);
            result.content = try gpa.alloc(u8, 0);
            const content = try sqlite.columnText(gpa, stmt, 0);
            gpa.free(result.content);
            result.content = content;
            result.truncated = sqlite.c.sqlite3_column_int(stmt, 1) != 0;
            result.observed_bytes = @intCast(sqlite.c.sqlite3_column_int64(stmt, 2));
        },
        sqlite.c.SQLITE_DONE => {},
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
pub fn importSession(store: *Store, value: *const SessionStartedType) !void {
    const stmt = store.import_session;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(raw_module(value.pane_id)));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    sqlite.bindText(stmt, 6, value.workspace_path);
    sqlite.bindText(stmt, 7, value.shell);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try sqlite.stepDone(stmt);
}

/// Ensures an agent-originated command has a parent session even when its
/// source reported before normal pane-session persistence completed.
///
/// ```zig
/// try store.ensureCommandSession(command);
/// ```
pub fn ensureCommandSession(store: *Store, value: *const CommandFinishedType) !void {
    const stmt = store.import_session;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.session_id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(raw_module(value.pane_id)));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    sqlite.bindText(stmt, 6, value.workspace_path);
    sqlite.bindText(stmt, 7, "");
    _ = sqlite.c.sqlite3_bind_int64(stmt, 8, value.started_at_ms);
    try sqlite.stepDone(stmt);
}

/// Idempotent command insert for imports, keyed by the unique
/// (session id, sequence) pair.
///
/// ```zig
/// try store.importCommand(&value);
/// ```
pub fn importCommand(store: *Store, value: *const CommandFinishedType) !void {
    const stmt = store.import_command;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.session_id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(raw_module(value.pane_id)));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 6, @intCast(value.sequence));
    sqlite.bindText(stmt, 7, value.command);
    _ = sqlite.c.sqlite3_bind_int(stmt, 8, @intFromBool(value.command_truncated));
    sqlite.bindText(stmt, 9, value.cwd);
    sqlite.bindText(stmt, 10, value.workspace_path);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 11, value.started_at_ms);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 12, value.duration_ns);
    if (value.exit_code) |exit_code| {
        _ = sqlite.c.sqlite3_bind_int(stmt, 13, exit_code);
    } else {
        _ = sqlite.c.sqlite3_bind_null(stmt, 13);
    }
    _ = sqlite.c.sqlite3_bind_int(stmt, 14, @intFromEnum(value.status));
    _ = sqlite.c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
    sqlite.bindCommandSource(stmt, value);
    try sqlite.stepDone(stmt);
}

pub fn finishSession(store: *Store, value: SessionFinishedType) !void {
    const stmt = store.finish_session;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, value.finished_at_ms);
    try sqlite.stepDone(stmt);
}

pub fn setSessionTitle(store: *Store, value: *const SessionTitleType) !void {
    const stmt = store.set_session_title;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.id);
    sqlite.bindText(stmt, 2, value.titleSlice());
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, @intFromEnum(value.source));
    _ = sqlite.c.sqlite3_bind_int(stmt, 4, @intFromEnum(value.state));
    try sqlite.stepDone(stmt);
    if (sqlite.c.sqlite3_changes(store.db) != 1) {
        return error.HistorySessionNotFound;
    }
}

pub fn insertCommand(store: *Store, value: *const CommandFinishedType) !bool {
    const stmt = store.insert_command;
    defer sqlite.reset(stmt);
    sqlite.bindBlob(stmt, 1, &value.session_id);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 2, @intCast(raw_module(value.pane_id)));
    const location = sqlite.locationColumns(value.location);
    _ = sqlite.c.sqlite3_bind_int(stmt, 3, location.kind);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 4, @intCast(location.id));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, @intCast(raw_module(value.location.tab_id)));
    _ = sqlite.c.sqlite3_bind_int64(stmt, 6, @intCast(value.sequence));
    sqlite.bindText(stmt, 7, value.command);
    _ = sqlite.c.sqlite3_bind_int(stmt, 8, @intFromBool(value.command_truncated));
    sqlite.bindText(stmt, 9, value.cwd);
    sqlite.bindText(stmt, 10, value.workspace_path);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 11, value.started_at_ms);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 12, value.duration_ns);
    if (value.exit_code) |exit_code| {
        _ = sqlite.c.sqlite3_bind_int(stmt, 13, exit_code);
    } else {
        _ = sqlite.c.sqlite3_bind_null(stmt, 13);
    }
    _ = sqlite.c.sqlite3_bind_int(stmt, 14, @intFromEnum(value.status));
    _ = sqlite.c.sqlite3_bind_int(stmt, 15, @intFromEnum(value.author));
    sqlite.bindCommandSource(stmt, value);
    try sqlite.stepDone(stmt);
    return sqlite.c.sqlite3_changes(store.db) == 1;
}

/// Closes a hook-started command without changing its stable row id.
/// Returns false when no matching start was persisted.
///
/// ```zig
/// if (!try store.finishAgentCommand(command)) _ = try store.insertCommand(command);
/// ```
pub fn finishAgentCommand(store: *Store, value: *const CommandFinishedType) !bool {
    if (value.tool_call_id.len == 0) {
        return false;
    }

    const stmt = store.finish_agent_command;
    defer sqlite.reset(stmt);
    sqlite.bindText(stmt, 1, value.command);
    _ = sqlite.c.sqlite3_bind_int(stmt, 2, @intFromBool(value.command_truncated));
    sqlite.bindText(stmt, 3, value.cwd);
    sqlite.bindText(stmt, 4, value.workspace_path);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 5, value.started_at_ms);
    if (value.exit_code) |exit_code| {
        _ = sqlite.c.sqlite3_bind_int(stmt, 6, exit_code);
    } else {
        _ = sqlite.c.sqlite3_bind_null(stmt, 6);
    }
    _ = sqlite.c.sqlite3_bind_int(stmt, 7, @intFromEnum(value.status));
    _ = sqlite.c.sqlite3_bind_int(stmt, 8, @intFromEnum(value.author));
    _ = sqlite.c.sqlite3_bind_int(stmt, 9, @intFromEnum(value.origin));
    if (value.provider.len == 0) {
        _ = sqlite.c.sqlite3_bind_null(stmt, 10);
    } else {
        sqlite.bindText(stmt, 10, value.provider);
    }
    sqlite.bindBlob(stmt, 11, &value.session_id);
    sqlite.bindText(stmt, 12, value.tool_call_id);
    try sqlite.stepDone(stmt);
    return sqlite.c.sqlite3_changes(store.db) == 1;
}

/// Fuzzy path: scans the newest candidates in scope and keeps the best
/// requested page of subsequence matches. Only IDs and scores are retained
/// while ranking; full entries are allocated for the resulting page.
fn queryFuzzy(store: *Store, gpa: std.mem.Allocator, request: *const QueryType) !*QueryResultType {
    const max_candidates = FuzzyPageType.max_candidates;
    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT " ++ sqlite.entry_columns ++ " FROM command WHERE id <= ?");
    try sqlite.appendQueryFilters(&sql, request);
    try sql.writeAll(" ORDER BY started_at_ms DESC, id DESC LIMIT ?;");

    const stmt = try sqlite.prepare(store.db, sql.buffered());
    defer _ = sqlite.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    _ = sqlite.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.snapshot_id));
    parameter += 1;
    sqlite.bindQueryFilters(stmt, &parameter, request);
    _ = sqlite.c.sqlite3_bind_int(stmt, parameter, max_candidates);

    var ranking = FuzzyPageType.init(request);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);

    while (true) switch (sqlite.c.sqlite3_step(stmt)) {
        sqlite.c.SQLITE_ROW => {
            const hash = sqlite.commandHash(stmt);
            if (request.distinct and seen.contains(hash)) {
                continue;
            }

            if (request.distinct) {
                try seen.put(gpa, hash, {});
            }

            ranking.consider(.{
                .id = sqlite.c.sqlite3_column_int64(stmt, 0),
                .command = sqlite.columnSlice(stmt, 6),
            }, request.textSlice());
        },
        sqlite.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };

    const detail = try sqlite.prepare(store.db, "SELECT " ++ sqlite.entry_columns ++ " FROM command WHERE id = ?;");
    defer _ = sqlite.c.sqlite3_finalize(detail);
    var accumulator: Accumulator = .{ .gpa = gpa, .limit = request.limit };
    defer accumulator.deinit();
    const start = @min(request.offset, ranking.count);
    const end = @min(start + request.limit, ranking.count);
    for (ranking.best[start..end]) |scored| {
        sqlite.reset(detail);
        _ = sqlite.c.sqlite3_bind_int64(detail, 1, scored.id);
        if (sqlite.c.sqlite3_step(detail) != sqlite.c.SQLITE_ROW) {
            return error.HistoryQueryFailed;
        }

        if (!try accumulator.append(try sqlite.readEntry(gpa, detail))) {
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
pub fn stats(store: *Store, gpa: std.mem.Allocator, request: *const StatsQueryType) !*StatsResultType {
    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT COUNT(*), COUNT(DISTINCT command) FROM command WHERE 1=1");
    try sqlite.appendStatsFilters(&sql, request);
    const totals_stmt = try sqlite.prepare(store.db, sql.buffered());
    var total: u64 = 0;
    var unique: u64 = 0;
    {
        defer _ = sqlite.c.sqlite3_finalize(totals_stmt);
        sqlite.bindStatsFilters(totals_stmt, request);
        switch (sqlite.c.sqlite3_step(totals_stmt)) {
            sqlite.c.SQLITE_ROW => {
                total = @intCast(sqlite.c.sqlite3_column_int64(totals_stmt, 0));
                unique = @intCast(sqlite.c.sqlite3_column_int64(totals_stmt, 1));
            },
            else => return error.HistoryQueryFailed,
        }
    }

    var top_sql_buffer: [1024]u8 = undefined;
    var top_sql = std.Io.Writer.fixed(&top_sql_buffer);
    try top_sql.writeAll("SELECT command, COUNT(*) AS n FROM command WHERE 1=1");
    try sqlite.appendStatsFilters(&top_sql, request);
    try top_sql.writeAll(" GROUP BY command ORDER BY n DESC LIMIT 400;");
    const stmt = try sqlite.prepare(store.db, top_sql.buffered());
    defer _ = sqlite.c.sqlite3_finalize(stmt);
    sqlite.bindStatsFilters(stmt, request);

    var buckets: std.StringHashMapUnmanaged(u64) = .empty;
    defer {
        var keys = buckets.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        buckets.deinit(gpa);
    }
    while (true) switch (sqlite.c.sqlite3_step(stmt)) {
        sqlite.c.SQLITE_ROW => {
            const command = sqlite.columnSlice(stmt, 0);
            const count: u64 = @intCast(sqlite.c.sqlite3_column_int64(stmt, 1));
            const key = policy.statsGroupKey(command);
            if (buckets.getPtr(key)) |slot| {
                slot.* += count;
            } else {
                try buckets.put(gpa, try gpa.dupe(u8, key), count);
            }
        },
        sqlite.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };

    const Top = struct { count: u64, key: []const u8 };
    var best: [max_history_stats_top_module]Top = undefined;
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

    const result = try gpa.create(StatsResultType);
    errdefer gpa.destroy(result);
    const top = try gpa.alloc(StatsTopType, best_len);
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
    defer sqlite.reset(stmt);
    _ = sqlite.c.sqlite3_bind_int64(stmt, 1, @intCast(command_id));
    try sqlite.stepDone(stmt);
    return @intCast(sqlite.c.sqlite3_changes64(store.db));
}

/// Deletes every entry matching the bounded prune filters and returns
/// the removed count.
///
/// ```zig
/// const removed = try store.prune(&prune);
/// ```
pub fn prune(store: *Store, request: *const PruneType) !u64 {
    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("DELETE FROM command WHERE 1=1");
    var match_buffer: [2 * max_history_query_bytes + 2]u8 = undefined;
    const use_index = store.fts_available and sqlite.queryCharacters(request.matchSlice()) >= 3;
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

    const stmt = try sqlite.prepare(store.db, sql.buffered());
    defer _ = sqlite.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    if (request.match_len != 0) {
        sqlite.bindText(stmt, parameter, if (use_index)
            sqlite.ftsQuote(request.matchSlice(), &match_buffer)
        else
            request.matchSlice());
        parameter += 1;
    }
    if (request.before_ms != 0) {
        _ = sqlite.c.sqlite3_bind_int64(stmt, parameter, request.before_ms);
        parameter += 1;
    }
    switch (request.scope) {
        .global => {},
        .cwd, .workspace => {
            sqlite.bindText(stmt, parameter, request.scopeSlice());
            parameter += 1;
        },
        .pane => {
            _ = sqlite.c.sqlite3_bind_int64(
                stmt,
                parameter,
                @intCast(raw_module(request.pane_id)),
            );
            parameter += 1;
        },
    }
    try sqlite.stepDone(stmt);
    return @intCast(sqlite.c.sqlite3_changes64(store.db));
}

/// Executes one bounded history query and returns an owned result that the
/// caller must deinitialize.
///
/// ```zig
/// const result = try store.query(gpa, &request);
/// ```
pub fn query(store: *Store, gpa: std.mem.Allocator, original: *const QueryType) !*QueryResultType {
    var bounded = original.*;
    if (bounded.snapshot_id == 0) {
        const boundary = try sqlite.prepare(store.db, "SELECT COALESCE(MAX(id), 0) FROM command;");
        defer _ = sqlite.c.sqlite3_finalize(boundary);
        if (sqlite.c.sqlite3_step(boundary) != sqlite.c.SQLITE_ROW) {
            return error.HistoryQueryFailed;
        }

        bounded.snapshot_id = @intCast(sqlite.c.sqlite3_column_int64(boundary, 0));
    }

    const request = &bounded;
    if (request.match == .fuzzy and request.text_len != 0 and request.entry_id == 0) {
        return store.queryFuzzy(gpa, request);
    }

    var sql_buffer: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buffer);
    try sql.writeAll("SELECT " ++ sqlite.entry_columns ++ " FROM command WHERE id <= ?");
    if (request.entry_id != 0) {
        try sql.writeAll(" AND id = ?");
    }
    // The trigram index probes instead of scanning the whole table, and
    // is case-insensitive like the fallback. Trigram matching needs at
    // least three characters; shorter queries take the scan.
    var match_buffer: [2 * max_history_query_bytes + 2]u8 = undefined;
    const use_index = store.fts_available and sqlite.queryCharacters(request.textSlice()) >= 3;
    if (request.text_len != 0) {
        if (use_index) {
            try sql.writeAll(
                " AND id IN (SELECT rowid FROM command_fts WHERE command_fts MATCH ?)",
            );
        } else {
            try sql.writeAll(" AND instr(lower(command), lower(?)) > 0");
        }
    }
    try sqlite.appendQueryFilters(&sql, request);
    try sql.writeAll(" ORDER BY started_at_ms DESC, id DESC LIMIT ? OFFSET ?;");

    const stmt = try sqlite.prepare(store.db, sql.buffered());
    defer _ = sqlite.c.sqlite3_finalize(stmt);
    var parameter: c_int = 1;
    _ = sqlite.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.snapshot_id));
    parameter += 1;
    if (request.entry_id != 0) {
        _ = sqlite.c.sqlite3_bind_int64(stmt, parameter, @intCast(request.entry_id));
        parameter += 1;
    }
    if (request.text_len != 0) {
        sqlite.bindText(stmt, parameter, if (use_index)
            sqlite.ftsQuote(request.textSlice(), &match_buffer)
        else
            request.textSlice());
        parameter += 1;
    }
    sqlite.bindQueryFilters(stmt, &parameter, request);
    _ = sqlite.c.sqlite3_bind_int(stmt, parameter, @as(c_int, request.limit) + 1);
    _ = sqlite.c.sqlite3_bind_int64(stmt, parameter + 1, request.offset);

    var accumulator: Accumulator = .{ .gpa = gpa, .limit = request.limit };
    defer accumulator.deinit();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    while (true) switch (sqlite.c.sqlite3_step(stmt)) {
        sqlite.c.SQLITE_ROW => {
            if (request.distinct) {
                if (seen.contains(sqlite.commandHash(stmt))) {
                    continue;
                }
                try seen.put(gpa, sqlite.commandHash(stmt), {});
            }

            if (accumulator.entries.items.len == request.limit) {
                accumulator.has_more = true;
                break;
            }

            if (!try accumulator.append(try sqlite.readEntry(gpa, stmt))) {
                break;
            }
        },
        sqlite.c.SQLITE_DONE => break,
        else => return error.HistoryQueryFailed,
    };
    return accumulator.finish(request, false);
}
