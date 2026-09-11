const Worker = @This();
const std = @import("std");
const sqlite = @import("persistence/sqlite.zig");
const metrics_mod = @import("metrics.zig");
const Context = @import("Context.zig");
const model = @import("model.zig");
const source_namespace = @import("worker_support.zig");
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
    var items: [64]model.Request = undefined;
    while (true) {
        const count = context.channel.receiveBatch(context.io, .{ .items = &items, .metrics = context.metrics }) catch |err| switch (err) {
            error.Closed => return,
            else => |other| return other,
        };
        var next: usize = 0;
        defer for (items[next..count]) |request| {
            model.deinitRequest(request, worker.gpa);
        };

        const path = source_namespace.diagnostics.enter(.observation);
        defer path.restore();

        while (next < count) {
            const request = items[next];
            next += 1;
            if (source_namespace.superseded(request, items[next..count])) {
                try context.channel.sendResponse(context.io, .{ .failed = .{
                    .request_id = request.query.request_id,
                    .origin = request.query.origin,
                    .message = "History query superseded",
                } });
                continue;
            }

            if (try worker.execute(context, request) == .stop) {
                return;
            }
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

fn execute(worker: *Worker, context: Context, request: model.Request) anyerror!source_namespace.Execution {
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

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn writeSessionStart(worker: *Worker, context: Context, value: *model.SessionStarted) void {
    defer value.deinit(worker.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (worker.database) |*database|
        database.startSession(value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn writeSessionFinish(worker: *Worker, context: Context, value: model.SessionFinished) void {
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (worker.database) |*database|
        database.finishSession(value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn writeSessionTitle(worker: *Worker, context: Context, value: model.SessionTitle) void {
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (worker.database) |*database|
        database.setSessionTitle(&value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn writeCommand(worker: *Worker, context: Context, value: *model.CommandFinished) void {
    defer value.deinit(worker.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (worker.database) |*database| write: {
        if (value.origin != .pane) {
            database.ensureCommandSession(value) catch |err| break :write err;
        }
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

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn writeImport(worker: *Worker, context: Context, batch: *model.ImportBatch) void {
    defer batch.deinit(worker.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (worker.database) |*database|
        source_namespace.writeImportBatch(database, batch)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(source_namespace.elapsedSince(context.io, started), result);
}

fn queryStats(worker: *Worker, context: Context, request: model.StatsQuery) void {
    const response: model.Response = if (worker.database) |*database| result: {
        const value = database.stats(worker.gpa, &request) catch break :result .{ .failed = .{
            .request_id = request.request_id,
            .origin = request.origin,
            .message = "history stats failed",
        } };

        break :result .{ .stats_result = value };
    } else source_namespace.unavailableResponse(request.request_id, request.origin);

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
    } else source_namespace.unavailableResponse(request.request_id, request.origin);

    context.channel.sendResponse(context.io, response) catch {
        model.deinitResponse(response, worker.gpa);
    };
}

fn deleteCommand(worker: *Worker, context: Context, request: model.Delete) void {
    const removed: u64 = if (worker.database) |*database|
        database.deleteCommand(request.id) catch 0
    else
        0;

    source_namespace.respondPruned(context, .{
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

    source_namespace.respondPruned(context, .{
        .request_id = request.request_id,
        .origin = request.origin,
        .removed = removed,
    });
}

fn query(worker: *Worker, context: Context, request: model.Query) anyerror!source_namespace.Execution {
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
        source_namespace.unavailableResponse(request.request_id, request.origin);

    context.metrics.observeQuery(source_namespace.elapsedSince(context.io, started), response == .failed);
    context.channel.sendResponse(context.io, response) catch |err| {
        model.deinitResponse(response, worker.gpa);

        if (err == error.Closed) {
            return .stop;
        }

        return err;
    };

    return .continue_running;
}
