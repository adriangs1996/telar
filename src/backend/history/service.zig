//! Application facade for command history.

const std = @import("std");
const core = @import("telar-core");
const channel_mod = @import("channel.zig");
const metrics_mod = @import("metrics.zig");
const model = @import("model.zig");
const request_factory = @import("request_factory.zig");
const terminal = @import("terminal.zig");
const worker_mod = @import("worker.zig");

pub const Service = struct {
    gpa: std.mem.Allocator,
    channel: channel_mod.Channel,
    worker: worker_mod.Worker,
    filters: core.history_filter.Filters,
    capture_output: bool,
    stats: Stats = .{},

    pub const Config = struct {
        database_path: [:0]const u8,
        filters: core.history_filter.Filters = .{},
        capture_output: bool = false,
    };

    pub const Stats = metrics_mod.Counters;
    pub const StatsSnapshot = metrics_mod.Snapshot;
    pub const LaunchAttemptRequest = request_factory.LaunchAttemptRequest;
    pub const SessionStartRequest = request_factory.SessionStartRequest;
    pub const CommandContext = request_factory.CommandContext;
    pub const CommandRecord = request_factory.CommandRecord;

    /// Creates the bounded history channel and opens its SQLite adapter. A
    /// database-open failure produces an observable degraded service instead
    /// of failing initialization.
    ///
    /// ```zig
    /// var service = try Service.init(gpa, .{ .database_path = ":memory:" });
    /// ```
    pub fn init(gpa: std.mem.Allocator, config: Config) !Service {
        const channel = try channel_mod.Channel.init(gpa);
        var stats: Stats = .{};

        return .{
            .gpa = gpa,
            .channel = channel,
            .worker = worker_mod.Worker.init(gpa, config.database_path, &stats),
            .filters = config.filters,
            .capture_output = config.capture_output,
            .stats = stats,
        };
    }

    /// Signals producers and the worker to stop. Call this before joining the
    /// worker and destroying the service.
    ///
    /// ```zig
    /// service.stop(io);
    /// ```
    pub fn stop(service: *Service, io: std.Io) void {
        service.channel.close(io);
    }

    /// Releases queued values, queue storage, and the SQLite connection after
    /// the worker has stopped.
    ///
    /// ```zig
    /// service.deinit(io);
    /// ```
    pub fn deinit(service: *Service, io: std.Io) void {
        service.channel.deinit(io);
        service.worker.deinit();
    }

    /// Runs the sequential history worker until `stop` closes its channel.
    ///
    /// ```zig
    /// try service.run(io);
    /// ```
    pub fn run(service: *Service, io: std.Io) anyerror!void {
        return service.worker.run(.{ .io = io, .channel = &service.channel, .metrics = &service.stats });
    }

    /// Waits for the next asynchronous query response and transfers ownership
    /// of it to the caller.
    ///
    /// ```zig
    /// const response = try service.receiveResponse(io);
    /// ```
    pub fn receiveResponse(service: *Service, io: std.Io) anyerror!model.Response {
        return service.channel.receiveResponse(io);
    }

    /// Reports whether pane observers should retain bounded command output.
    ///
    /// ```zig
    /// const enabled = service.capturesOutput();
    /// ```
    pub fn capturesOutput(service: *const Service) bool {
        return service.capture_output;
    }

    /// Generates a session identifier with the runtime I/O entropy source.
    ///
    /// ```zig
    /// const session_id = service.newSessionId(io);
    /// ```
    pub fn newSessionId(_: *Service, io: std.Io) model.SessionId {
        var session_id: model.SessionId = undefined;
        io.random(&session_id);
        return session_id;
    }

    /// Copies and queues one failed pane-launch transaction for persistence.
    ///
    /// ```zig
    /// _ = service.recordLaunchAttempt(io, request);
    /// ```
    pub fn recordLaunchAttempt(service: *Service, io: std.Io, request: LaunchAttemptRequest) bool {
        const owned = request_factory.launchAttempt(service.gpa, io, request) catch return false;
        return service.submit(io, owned);
    }

    /// Copies and queues the immutable identity of one committed pane session.
    ///
    /// ```zig
    /// _ = service.startSession(io, request);
    /// ```
    pub fn startSession(service: *Service, io: std.Io, request: SessionStartRequest) bool {
        const owned = request_factory.sessionStarted(service.gpa, request) catch return false;
        return service.submit(io, owned);
    }

    /// Queues the terminal timestamp for one history session.
    ///
    /// ```zig
    /// _ = service.finishSession(io, finished);
    /// ```
    pub fn finishSession(service: *Service, io: std.Io, finished: model.SessionFinished) bool {
        return service.submit(io, .{ .session_finished = finished });
    }

    /// Validates and queues the latest authoritative title state for a session.
    ///
    /// ```zig
    /// _ = service.setSessionTitle(io, definition);
    /// ```
    pub fn setSessionTitle(service: *Service, io: std.Io, definition: model.SessionTitle.Definition) bool {
        const request = request_factory.sessionTitle(definition) catch return false;
        return service.submit(io, request);
    }

    /// Copies one wire import batch into owned storage and queues it for the
    /// history worker.
    ///
    /// ```zig
    /// if (!service.importBatch(io, view)) return error.ImportRefused;
    /// ```
    pub fn importBatch(service: *Service, io: std.Io, view: model.schema.ImportHistoryView) bool {
        const request = request_factory.importBatch(service.gpa, view) catch return false;
        return service.submit(io, request);
    }

    /// Queues one exact-entry deletion and produces an asynchronous response.
    ///
    /// ```zig
    /// _ = service.deleteHistory(io, request);
    /// ```
    pub fn deleteHistory(service: *Service, io: std.Io, request: model.Delete) bool {
        return service.submit(io, .{ .delete = request });
    }

    /// Queues one bounded prune and produces an asynchronous response.
    ///
    /// ```zig
    /// _ = service.pruneHistory(io, prune);
    /// ```
    pub fn pruneHistory(service: *Service, io: std.Io, prune: model.Prune) bool {
        return service.submit(io, .{ .prune = prune });
    }

    /// Queues one captured-output read and produces an asynchronous response.
    ///
    /// ```zig
    /// _ = service.readOutput(io, request);
    /// ```
    pub fn readOutput(service: *Service, io: std.Io, request: model.Delete) bool {
        return service.submit(io, .{ .read_output = request });
    }

    /// Queues one history aggregation and produces an asynchronous response.
    ///
    /// ```zig
    /// _ = service.statsHistory(io, query);
    /// ```
    pub fn statsHistory(service: *Service, io: std.Io, stats_query: model.StatsQuery) bool {
        return service.submit(io, .{ .stats = stats_query });
    }

    /// Copies one completed command into owned storage after applying the
    /// record-time filters, then offers it to the bounded worker channel.
    ///
    /// ```zig
    /// _ = service.recordCommand(io, record);
    /// ```
    pub fn recordCommand(service: *Service, io: std.Io, record: CommandRecord) bool {
        if (!service.filters.shouldRecord(record.command.bytes, record.command.cwd)) {
            return true;
        }

        const request = request_factory.commandFinished(service.gpa, record) catch return false;
        return service.submit(io, request);
    }

    /// Queues one history search and produces an asynchronous response.
    ///
    /// ```zig
    /// _ = service.query(io, request);
    /// ```
    pub fn query(service: *Service, io: std.Io, request: model.Query) bool {
        return service.submit(io, .{ .query = request });
    }

    /// Samples lock-free service metrics without blocking history work.
    ///
    /// ```zig
    /// const stats = service.statsSnapshot();
    /// ```
    pub fn statsSnapshot(service: *const Service) StatsSnapshot {
        return service.stats.snapshot(service.worker.available());
    }

    /// Samples the current on-disk SQLite file size for telemetry.
    ///
    /// ```zig
    /// const bytes = service.sqliteBytes(io);
    /// ```
    pub fn sqliteBytes(service: *const Service, io: std.Io) u64 {
        return service.worker.sqliteBytes(io);
    }

    /// Returns the retained database-open error when the service is degraded.
    ///
    /// ```zig
    /// const failure = service.openError();
    /// ```
    pub fn openError(service: *const Service) ?anyerror {
        return service.worker.openError();
    }

    fn submit(service: *Service, io: std.Io, request: model.Request) bool {
        return service.channel.submit(.{ .io = io, .request = request, .metrics = &service.stats });
    }
};

test "service configuration controls recording and output capture" {
    const io = std.testing.io;
    var filters: core.history_filter.Filters = .{};
    try filters.commands.add("vault kv");
    var service = try Service.init(std.testing.allocator, .{
        .database_path = ":memory:",
        .filters = filters,
        .capture_output = true,
    });
    defer {
        service.stop(io);
        service.deinit(io);
    }
    const context: Service.CommandContext = .{
        .session_id = @splat(7),
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) },
        .sequence = 1,
        .workspace_path = "/work",
        .cols = 80,
        .rows = 24,
    };
    const command: terminal.Command = .{
        .bytes = "vault kv get secret/x",
        .cwd = "/work",
        .started_at_ms = 1,
        .duration_ns = 1,
        .exit_code = 0,
        .status = .completed,
        .truncated = false,
    };

    try std.testing.expect(service.capturesOutput());
    try std.testing.expect(service.recordCommand(io, .{ .context = context, .command = command }));
    try std.testing.expectEqual(@as(u64, 0), service.statsSnapshot().queued);

    var accepted = command;
    accepted.bytes = "git status";
    try std.testing.expect(service.recordCommand(io, .{ .context = context, .command = accepted }));
    try std.testing.expectEqual(@as(u64, 1), service.statsSnapshot().queued);
}

test "database open degradation remains visible through the service facade" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var service = try Service.init(std.testing.allocator, .{ .database_path = path });
    defer service.deinit(io);

    const stats = service.statsSnapshot();

    try std.testing.expect(!stats.available);
    try std.testing.expectEqual(@as(u64, 1), stats.sqlite_open_failures);
    try std.testing.expect(service.openError() != null);
}
