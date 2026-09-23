const core = @import("telar-core");
const std = @import("std");
const Store = @import("persistence/Store.zig");
const Counters = @import("Counters.zig");
const Context = @import("Context.zig");
const model = @import("model.zig");
const worker_support = @import("worker_support.zig");
const LaunchAttempt = @import("LaunchAttempt.zig");
const SessionStarted = @import("SessionStarted.zig");
const SessionFinished = @import("SessionFinished.zig");
const SessionTitle = @import("SessionTitle.zig");
const CommandFinished = @import("CommandFinished.zig");
const ImportBatch = @import("ImportBatch.zig");
const StatsQuery = @import("StatsQuery.zig");
const Delete = @import("Delete.zig");
const Prune = @import("Prune.zig");
const Query = @import("Query.zig");
const Worker = @This();

gpa: std.mem.Allocator,
database_path: [:0]const u8,
database: ?Store,
open_error: ?anyerror,

/// Opens the selected SQLite database or creates an explicit degraded
/// worker when opening fails. History producers remain operational in
/// either state.
///
/// ```zig
/// var worker = Worker.init(gpa, database_path, metrics);
/// defer worker.deinit();
/// ```
pub fn init(gpa: std.mem.Allocator, database_path: [:0]const u8, metrics: *Counters) Worker {
    var open_error: ?anyerror = null;
    const database = Store.open(database_path) catch |err| unavailable: {
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
pub fn deinit(self: *Worker) void {
    if (self.database) |*database| {
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
pub fn run(self: *Worker, context: Context) anyerror!void {
    var items: [64]model.Request = undefined;
    while (true) {
        const count = context.channel.receiveBatch(context.io, .{ .items = &items, .metrics = context.metrics }) catch |err| switch (err) {
            error.Closed => return,
            else => |other| return other,
        };
        var next: usize = 0;
        defer for (items[next..count]) |request| {
            model.deinitRequest(request, self.gpa);
        };

        const path = core.enter(.observation);
        defer path.restore();

        while (next < count) {
            const request = items[next];
            next += 1;
            if (worker_support.superseded(request, items[next..count])) {
                try context.channel.sendResponse(context.io, .{ .failed = .{
                    .request_id = request.query.request_id,
                    .origin = request.query.origin,
                    .message = "History query superseded",
                } });
                continue;
            }

            if (try self.execute(context, request) == .stop) {
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
pub fn available(self: *const Worker) bool {
    return self.database != null;
}

/// Returns the database-open failure retained by a degraded worker.
///
/// ```zig
/// const failure = worker.openError();
/// ```
pub fn openError(self: *const Worker) ?anyerror {
    return self.open_error;
}

/// Samples the current on-disk SQLite size for telemetry. In-memory and
/// unavailable databases report zero.
///
/// ```zig
/// const bytes = worker.sqliteBytes(io);
/// ```
pub fn sqliteBytes(self: *const Worker, io: std.Io) u64 {
    if (std.mem.eql(u8, self.database_path, ":memory:")) {
        return 0;
    }

    const stat = std.Io.Dir.cwd().statFile(io, self.database_path, .{ .follow_symlinks = false }) catch return 0;
    if (stat.size < 0) {
        return 0;
    }

    return @intCast(stat.size);
}

fn execute(self: *Worker, context: Context, request: model.Request) anyerror!worker_support.Execution {
    switch (request) {
        .launch_attempt => |value| self.writeLaunchAttempt(context, value),
        .session_started => |value| self.writeSessionStart(context, value),
        .session_finished => |value| self.writeSessionFinish(context, value),
        .session_title => |value| self.writeSessionTitle(context, value),
        .command_finished => |value| self.writeCommand(context, value),
        .import => |value| self.writeImport(context, value),
        .stats => |value| self.queryStats(context, value),
        .read_output => |value| self.readOutput(context, value),
        .delete => |value| self.deleteCommand(context, value),
        .prune => |value| self.prune(context, value),
        .query => |value| return self.query(context, value),
    }

    return .continue_running;
}

fn writeLaunchAttempt(self: *Worker, context: Context, value: *LaunchAttempt) void {
    defer value.deinit(self.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database|
        database.insertLaunchAttempt(value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn writeSessionStart(self: *Worker, context: Context, value: *SessionStarted) void {
    defer value.deinit(self.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database|
        database.startSession(value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn writeSessionFinish(self: *Worker, context: Context, value: SessionFinished) void {
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database|
        database.finishSession(value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn writeSessionTitle(self: *Worker, context: Context, value: SessionTitle) void {
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database|
        database.setSessionTitle(&value)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn writeCommand(self: *Worker, context: Context, value: *CommandFinished) void {
    defer value.deinit(self.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database| write: {
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

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn writeImport(self: *Worker, context: Context, batch: *ImportBatch) void {
    defer batch.deinit(self.gpa);
    const started = std.Io.Timestamp.now(context.io, .awake);
    const result = if (self.database) |*database|
        worker_support.writeImportBatch(database, batch)
    else
        error.HistoryUnavailable;

    context.metrics.observeWrite(worker_support.elapsedSince(context.io, started), result);
}

fn queryStats(self: *Worker, context: Context, request: StatsQuery) void {
    const response: model.Response = if (self.database) |*database| result: {
        const value = database.stats(self.gpa, &request) catch break :result .{ .failed = .{
            .request_id = request.request_id,
            .origin = request.origin,
            .message = "history stats failed",
        } };

        break :result .{ .stats_result = value };
    } else worker_support.unavailableResponse(request.request_id, request.origin);

    context.channel.sendResponse(context.io, response) catch {
        model.deinitResponse(response, self.gpa);
    };
}

fn readOutput(self: *Worker, context: Context, request: Delete) void {
    const response: model.Response = if (self.database) |*database| result: {
        const value = database.readCommandOutput(self.gpa, request) catch break :result .{ .failed = .{
            .request_id = request.request_id,
            .origin = request.origin,
            .message = "history output read failed",
        } };

        break :result .{ .output_result = value };
    } else worker_support.unavailableResponse(request.request_id, request.origin);

    context.channel.sendResponse(context.io, response) catch {
        model.deinitResponse(response, self.gpa);
    };
}

fn deleteCommand(self: *Worker, context: Context, request: Delete) void {
    const removed: u64 = if (self.database) |*database|
        database.deleteCommand(request.id) catch 0
    else
        0;

    worker_support.respondPruned(context, .{
        .request_id = request.request_id,
        .origin = request.origin,
        .removed = removed,
    });
}

fn prune(self: *Worker, context: Context, request: Prune) void {
    const removed: u64 = if (self.database) |*database|
        database.prune(&request) catch 0
    else
        0;

    worker_support.respondPruned(context, .{
        .request_id = request.request_id,
        .origin = request.origin,
        .removed = removed,
    });
}

fn query(self: *Worker, context: Context, request: Query) anyerror!worker_support.Execution {
    const started = std.Io.Timestamp.now(context.io, .awake);
    const response: model.Response = if (self.database) |*database|
        if (database.query(self.gpa, &request)) |result|
            .{ .query_result = result }
        else |_|
            .{ .failed = .{
                .request_id = request.request_id,
                .origin = request.origin,
                .message = "history query failed",
            } }
    else
        worker_support.unavailableResponse(request.request_id, request.origin);

    context.metrics.observeQuery(worker_support.elapsedSince(context.io, started), response == .failed);
    context.channel.sendResponse(context.io, response) catch |err| {
        model.deinitResponse(response, self.gpa);

        if (err == error.Closed) {
            return .stop;
        }

        return err;
    };

    return .continue_running;
}
