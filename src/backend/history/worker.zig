//! Sequential execution of history requests against durable storage.

const std = @import("std");
const core = @import("telar-core");
const channel_mod = @import("channel.zig");
const metrics_mod = @import("metrics.zig");
const model = @import("model.zig");
const sqlite = @import("persistence/sqlite.zig");

const diagnostics = core.diagnostics;

pub const Context = struct {
    io: std.Io,
    channel: *channel_mod.Channel,
    metrics: *metrics_mod.Counters,
};

const Execution = enum {
    continue_running,
    stop,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    database_path: [:0]const u8,
    database: ?sqlite.Store,
    open_error: ?anyerror,

    /// Opens the selected SQLite database or creates an explicit degraded
    /// worker when opening fails. History producers remain operational in
    /// either state.
    ///
    /// ```zig
    /// var worker = Worker.init(gpa, database_path, metrics);
    /// defer worker.deinit();
    /// ```
    pub fn init(gpa: std.mem.Allocator, database_path: [:0]const u8, metrics: *metrics_mod.Counters) Worker {
        var open_error: ?anyerror = null;
        const database = sqlite.Store.open(database_path) catch |err| unavailable: {
            open_error = err;
            break :unavailable null;
        };

        if (open_error != null) {
            metrics.recordOpenFailure();
        }

        return .{
            .gpa = gpa,
            .database_path = database_path,
            .database = database,
            .open_error = open_error,
        };
    }

    /// Closes the database after request execution has stopped.
    ///
    /// ```zig
    /// worker.deinit();
    /// ```
    pub fn deinit(worker: *Worker) void {
        if (worker.database) |*database| {
            database.close();
        }
    }

    /// Consumes owned requests in queue order until the request channel closes.
    /// Storage failures update telemetry or produce correlated failure responses
    /// without crashing producers.
    ///
    /// ```zig
    /// try worker.run(.{ .io = io, .channel = channel, .metrics = metrics });
    /// ```
    pub fn run(worker: *Worker, context: Context) anyerror!void {
        while (true) {
            const request = context.channel.receiveRequest(context.io, context.metrics) catch |err| switch (err) {
                error.Closed => return,
                else => |other| return other,
            };
            const path = diagnostics.enter(.observation);
            defer path.restore();

            if (try worker.execute(context, request) == .stop) {
                return;
            }
        }
    }

    /// Reports whether this worker has a usable database connection.
    ///
    /// ```zig
    /// const available = worker.available();
    /// ```
    pub fn available(worker: *const Worker) bool {
        return worker.database != null;
    }

    /// Returns the database-open failure retained by a degraded worker.
    ///
    /// ```zig
    /// const failure = worker.openError();
    /// ```
    pub fn openError(worker: *const Worker) ?anyerror {
        return worker.open_error;
    }

    /// Samples the current on-disk SQLite size for telemetry. In-memory and
    /// unavailable databases report zero.
    ///
    /// ```zig
    /// const bytes = worker.sqliteBytes(io);
    /// ```
    pub fn sqliteBytes(worker: *const Worker, io: std.Io) u64 {
        if (std.mem.eql(u8, worker.database_path, ":memory:")) {
            return 0;
        }

        const stat = std.Io.Dir.cwd().statFile(io, worker.database_path, .{ .follow_symlinks = false }) catch return 0;
        if (stat.size < 0) {
            return 0;
        }

        return @intCast(stat.size);
    }

    fn execute(worker: *Worker, context: Context, request: model.Request) anyerror!Execution {
        switch (request) {
            .launch_attempt => |value| worker.writeLaunchAttempt(context, value),
            .session_started => |value| worker.writeSessionStart(context, value),
            .session_finished => |value| worker.writeSessionFinish(context, value),
            .session_title => |value| worker.writeSessionTitle(context, value),
            .command_finished => |value| worker.writeCommand(context, value),
            .import => |value| worker.writeImport(context, value),
            .stats => |value| worker.queryStats(context, value),
            .read_output => |value| worker.readOutput(context, value),
            .delete => |value| worker.deleteCommand(context, value),
            .prune => |value| worker.prune(context, value),
            .query => |value| return worker.query(context, value),
        }

        return .continue_running;
    }

    fn writeLaunchAttempt(worker: *Worker, context: Context, value: *model.LaunchAttempt) void {
        defer value.deinit(worker.gpa);
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database|
            database.insertLaunchAttempt(value)
        else
            error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn writeSessionStart(worker: *Worker, context: Context, value: *model.SessionStarted) void {
        defer value.deinit(worker.gpa);
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database|
            database.startSession(value)
        else
            error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn writeSessionFinish(worker: *Worker, context: Context, value: model.SessionFinished) void {
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database|
            database.finishSession(value)
        else
            error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn writeSessionTitle(worker: *Worker, context: Context, value: model.SessionTitle) void {
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database|
            database.setSessionTitle(&value)
        else
            error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn writeCommand(worker: *Worker, context: Context, value: *model.CommandFinished) void {
        defer value.deinit(worker.gpa);
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database| write: {
            if (value.origin != .pane) database.ensureCommandSession(value) catch |err| break :write err;
            const updated = if (value.origin == .hook and value.status != .running)
                database.finishAgentCommand(value) catch |err| break :write err
            else
                false;
            const inserted = if (updated)
                false
            else
                database.insertCommand(value) catch |err| break :write err;
            if (inserted and value.output_observed > 0) {
                database.insertCommandOutput(value) catch |err| break :write err;
            }

            break :write {};
        } else error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn writeImport(worker: *Worker, context: Context, batch: *model.ImportBatch) void {
        defer batch.deinit(worker.gpa);
        const started = std.Io.Timestamp.now(context.io, .awake);
        const result = if (worker.database) |*database|
            writeImportBatch(database, batch)
        else
            error.HistoryUnavailable;

        context.metrics.observeWrite(elapsedSince(context.io, started), result);
    }

    fn queryStats(worker: *Worker, context: Context, request: model.StatsQuery) void {
        const response: model.Response = if (worker.database) |*database| result: {
            const value = database.stats(worker.gpa, &request) catch break :result .{ .failed = .{
                .request_id = request.request_id,
                .origin = request.origin,
                .message = "history stats failed",
            } };

            break :result .{ .stats_result = value };
        } else unavailableResponse(request.request_id, request.origin);

        context.channel.sendResponse(context.io, response) catch {
            model.deinitResponse(response, worker.gpa);
        };
    }

    fn readOutput(worker: *Worker, context: Context, request: model.Delete) void {
        const response: model.Response = if (worker.database) |*database| result: {
            const value = database.readCommandOutput(worker.gpa, request) catch break :result .{ .failed = .{
                .request_id = request.request_id,
                .origin = request.origin,
                .message = "history output read failed",
            } };

            break :result .{ .output_result = value };
        } else unavailableResponse(request.request_id, request.origin);

        context.channel.sendResponse(context.io, response) catch {
            model.deinitResponse(response, worker.gpa);
        };
    }

    fn deleteCommand(worker: *Worker, context: Context, request: model.Delete) void {
        const removed: u64 = if (worker.database) |*database|
            database.deleteCommand(request.id) catch 0
        else
            0;

        respondPruned(context, .{
            .request_id = request.request_id,
            .origin = request.origin,
            .removed = removed,
        });
    }

    fn prune(worker: *Worker, context: Context, request: model.Prune) void {
        const removed: u64 = if (worker.database) |*database|
            database.prune(&request) catch 0
        else
            0;

        respondPruned(context, .{
            .request_id = request.request_id,
            .origin = request.origin,
            .removed = removed,
        });
    }

    fn query(worker: *Worker, context: Context, request: model.Query) anyerror!Execution {
        const started = std.Io.Timestamp.now(context.io, .awake);
        const response: model.Response = if (worker.database) |*database|
            if (database.query(worker.gpa, &request)) |result|
                .{ .query_result = result }
            else |_|
                .{ .failed = .{
                    .request_id = request.request_id,
                    .origin = request.origin,
                    .message = "history query failed",
                } }
        else
            unavailableResponse(request.request_id, request.origin);

        context.metrics.observeQuery(elapsedSince(context.io, started), response == .failed);
        context.channel.sendResponse(context.io, response) catch |err| {
            model.deinitResponse(response, worker.gpa);

            if (err == error.Closed) {
                return .stop;
            }

            return err;
        };

        return .continue_running;
    }
};

fn unavailableResponse(request_id: model.schema.RequestId, origin: model.QueryOrigin) model.Response {
    return .{ .failed = .{
        .request_id = request_id,
        .origin = origin,
        .message = "history database is unavailable",
    } };
}

fn respondPruned(context: Context, pruned: model.Pruned) void {
    context.channel.sendResponse(context.io, .{ .pruned = pruned }) catch {};
}

/// Writes one imported session and its commands idempotently. Both SQLite
/// operations use `OR IGNORE`, keyed by deterministic session and sequence.
fn writeImportBatch(database: *sqlite.Store, batch: *const model.ImportBatch) anyerror!void {
    const session: model.SessionStarted = .{
        .id = batch.session_id,
        .pane_id = batch.pane_id,
        .location = batch.location,
        .started_at_ms = batch.started_at_ms,
        .workspace_path = @constCast(""),
        .shell = batch.source,
    };
    try database.importSession(&session);

    for (batch.commands, batch.times, 0..) |command, time, index| {
        var value: model.CommandFinished = .{
            .session_id = batch.session_id,
            .pane_id = batch.pane_id,
            .location = batch.location,
            .sequence = batch.base_sequence + index,
            .started_at_ms = time,
            .duration_ns = 0,
            .exit_code = null,
            .status = .completed,
            .author = .human,
            .cols = 0,
            .rows = 0,
            .command = command,
            .cwd = @constCast(""),
            .workspace_path = @constCast(""),
            .command_truncated = false,
            .output = @constCast(""),
            .output_truncated = false,
            .output_observed = 0,
        };
        try database.importCommand(&value);
    }
}

fn elapsedSince(io: std.Io, started: std.Io.Timestamp) u64 {
    return elapsedNs(started, std.Io.Timestamp.now(io, .awake));
}

fn elapsedNs(started: std.Io.Timestamp, finished: std.Io.Timestamp) u64 {
    return @intCast(@max(@as(i96, 0), finished.nanoseconds - started.nanoseconds));
}

test "database open degradation is explicit" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var metrics: metrics_mod.Counters = .{};
    var worker = Worker.init(std.testing.allocator, path, &metrics);
    defer worker.deinit();

    try std.testing.expect(!worker.available());
    try std.testing.expect(worker.openError() != null);
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot(worker.available()).sqlite_open_failures);
}

test "sqlite byte sampling distinguishes memory and disk databases" {
    const io = std.testing.io;
    var metrics: metrics_mod.Counters = .{};
    var memory = Worker.init(std.testing.allocator, ":memory:", &metrics);
    defer memory.deinit();

    try std.testing.expectEqual(@as(u64, 0), memory.sqliteBytes(io));

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/history.db", .{directory_buffer[0..directory_len]});
    var disk = Worker.init(std.testing.allocator, path, &metrics);
    defer disk.deinit();

    try std.testing.expect(disk.available());
    try std.testing.expect(disk.sqliteBytes(io) > 0);
}

test "import batches remain idempotent at the worker storage boundary" {
    const gpa = std.testing.allocator;
    var database = try sqlite.Store.open(":memory:");
    defer database.close();
    var buffer: [512]u8 = undefined;
    const entries = [_]model.schema.ImportEntry{
        .{ .started_at_ms = 1_000, .command = "git status" },
        .{ .started_at_ms = 2_000, .command = "make -j4" },
    };
    const encoded = try model.schema.encodeImportHistory(&buffer, .{
        .request_id = @enumFromInt(3),
        .source = "zsh:/tmp/histfile",
        .base_sequence = 0,
        .entries = &entries,
    });
    const view = (try model.schema.decodeClient(encoded)).import_history;
    const first = try model.ImportBatch.init(gpa, view);
    defer first.deinit(gpa);
    const second = try model.ImportBatch.init(gpa, view);
    defer second.deinit(gpa);

    try writeImportBatch(&database, first);
    try writeImportBatch(&database, second);

    const origin: model.QueryOrigin = .{
        .client = .{ .id = 1, .generation = 1 },
        .close_after_reply = false,
    };
    const result = try database.query(gpa, &(try model.Query.init(.{
        .request_id = @enumFromInt(9),
        .origin = origin,
    })));
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqualStrings("make -j4", result.entries[0].command);
    try std.testing.expectEqual(model.schema.HistoryAuthor.human, result.entries[0].author);
}
