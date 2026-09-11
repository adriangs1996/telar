const ServiceConfig = @import("ServiceConfig.zig");
const CountersType = @import("Counters.zig");
const SnapshotType = @import("Snapshot.zig");
const LaunchAttemptRequestType = @import("LaunchAttemptRequest.zig");
const SessionStartRequestType = @import("SessionStartRequest.zig");
const CommandRecordType = @import("CommandRecord.zig");
const AgentCommandRecordType = @import("AgentCommandRecord.zig");
const std = @import("std");
const ChannelType = @import("Channel.zig");
const WorkerType = @import("Worker.zig");
const FiltersType = @import("telar-core").Filters;
const model = @import("model.zig");
const request_factory = @import("request_factory.zig");
const SessionFinishedType = @import("SessionFinished.zig");
const DefinitionType = @import("Definition.zig");
const ImportHistoryViewType = @import("telar-core").ImportHistoryView;
const DeleteType = @import("Delete.zig");
const PruneType = @import("Prune.zig");
const StatsQueryType = @import("StatsQuery.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const max_history_provider_bytes_module = @import("telar-core").max_history_provider_bytes;
const max_history_tool_call_id_bytes_module = @import("telar-core").max_history_tool_call_id_bytes;
const QueryType = @import("Query.zig");
const Service = @This();

gpa: std.mem.Allocator,
channel: ChannelType,
worker: WorkerType,
filters: FiltersType,
capture_output: bool,
stats: CountersType = .{},

pub const Config = @import("ServiceConfig.zig");

pub const Stats = @import("Counters.zig");
pub const StatsSnapshot = @import("Snapshot.zig");
pub const LaunchAttemptRequest = @import("LaunchAttemptRequest.zig");
pub const SessionStartRequest = @import("SessionStartRequest.zig");
pub const CommandContext = @import("CommandContext.zig");
pub const CommandRecord = @import("CommandRecord.zig");
pub const AgentCommandRecord = @import("AgentCommandRecord.zig");

/// Creates the bounded history channel and opens its SQLite adapter. A
/// database-open failure produces an observable degraded service instead
/// of failing initialization.
///
/// ```zig
/// var service = try Service.init(gpa, .{ .database_path = ":memory:" });
/// ```
pub fn init(gpa: std.mem.Allocator, config: ServiceConfig) !Service {
    const channel = try ChannelType.init(gpa);
    var stats: CountersType = .{};

    return .{
        .gpa = gpa,
        .channel = channel,
        .worker = WorkerType.init(gpa, config.database_path, &stats),
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
pub fn recordLaunchAttempt(service: *Service, io: std.Io, request: LaunchAttemptRequestType) bool {
    const owned = request_factory.launchAttempt(service.gpa, io, request) catch return false;
    return service.submit(io, owned);
}

/// Copies and queues the immutable identity of one committed pane session.
///
/// ```zig
/// _ = service.startSession(io, request);
/// ```
pub fn startSession(service: *Service, io: std.Io, request: SessionStartRequestType) bool {
    const owned = request_factory.sessionStarted(service.gpa, request) catch return false;
    return service.submit(io, owned);
}

/// Queues the terminal timestamp for one history session.
///
/// ```zig
/// _ = service.finishSession(io, finished);
/// ```
pub fn finishSession(service: *Service, io: std.Io, finished: SessionFinishedType) bool {
    return service.submit(io, .{ .session_finished = finished });
}

/// Validates and queues the latest authoritative title state for a session.
///
/// ```zig
/// _ = service.setSessionTitle(io, definition);
/// ```
pub fn setSessionTitle(service: *Service, io: std.Io, definition: DefinitionType) bool {
    const request = request_factory.sessionTitle(definition) catch return false;
    return service.submit(io, request);
}

/// Copies one wire import batch into owned storage and queues it for the
/// history worker.
///
/// ```zig
/// if (!service.importBatch(io, view)) return error.ImportRefused;
/// ```
pub fn importBatch(service: *Service, io: std.Io, view: ImportHistoryViewType) bool {
    const request = request_factory.importBatch(service.gpa, view) catch return false;
    return service.submit(io, request);
}

/// Queues one exact-entry deletion and produces an asynchronous response.
///
/// ```zig
/// _ = service.deleteHistory(io, request);
/// ```
pub fn deleteHistory(service: *Service, io: std.Io, request: DeleteType) bool {
    return service.submit(io, .{ .delete = request });
}

/// Queues one bounded prune and produces an asynchronous response.
///
/// ```zig
/// _ = service.pruneHistory(io, prune);
/// ```
pub fn pruneHistory(service: *Service, io: std.Io, prune: PruneType) bool {
    return service.submit(io, .{ .prune = prune });
}

/// Queues one captured-output read and produces an asynchronous response.
///
/// ```zig
/// _ = service.readOutput(io, request);
/// ```
pub fn readOutput(service: *Service, io: std.Io, request: DeleteType) bool {
    return service.submit(io, .{ .read_output = request });
}

/// Queues one history aggregation and produces an asynchronous response.
///
/// ```zig
/// _ = service.statsHistory(io, query);
/// ```
pub fn statsHistory(service: *Service, io: std.Io, stats_query: StatsQueryType) bool {
    return service.submit(io, .{ .stats = stats_query });
}

/// Copies one completed command into owned storage after applying the
/// record-time filters, then offers it to the bounded worker channel.
///
/// ```zig
/// _ = service.recordCommand(io, record);
/// ```
pub fn recordCommand(service: *Service, io: std.Io, record: CommandRecordType) bool {
    if (!service.filters.shouldRecord(.{ .command = record.command.bytes, .cwd = record.command.cwd })) {
        return true;
    }

    const request = request_factory.commandFinished(service.gpa, record) catch return false;
    return service.submit(io, request);
}

/// Queues an agent command with explicit provenance and optional secret
/// filtering. Leading spaces are data, not shell history control.
///
/// ```zig
/// _ = service.recordAgentCommand(io, record);
/// ```
pub fn recordAgentCommand(service: *Service, io: std.Io, record: AgentCommandRecordType) bool {
    if (record.origin == .pane) {
        return false;
    }
    if (record.phase == .started and record.tool_call_id.len == 0) {
        return true;
    }
    if (record.command.bytes.len == 0 or
        record.command.bytes.len > max_history_command_bytes_module or
        record.command.cwd.len > max_cwd_bytes_module or
        record.context.workspace_path.len > max_cwd_bytes_module or
        record.provider.len > max_history_provider_bytes_module or
        record.tool_call_id.len > max_history_tool_call_id_bytes_module)
    {
        return false;
    }
    if (!std.unicode.utf8ValidateSlice(record.provider) or
        !std.unicode.utf8ValidateSlice(record.tool_call_id) or
        std.mem.indexOfScalar(u8, record.provider, 0) != null or
        std.mem.indexOfScalar(u8, record.tool_call_id, 0) != null)
    {
        return false;
    }
    if (!service.filters.shouldRecordAgent(.{ .command = record.command.bytes, .cwd = record.command.cwd }, record.redact)) {
        return true;
    }

    var context = record.context;
    context.author = .agent;
    context.origin = record.origin;
    context.provider = record.provider;
    context.tool_call_id = record.tool_call_id;
    var request = request_factory.commandFinished(service.gpa, .{
        .context = context,
        .command = record.command,
    }) catch return false;
    request.command_finished.status = switch (record.phase) {
        .started => .running,
        .finished => request.command_finished.status,
    };
    return service.submit(io, request);
}

/// Queues one history search and produces an asynchronous response.
///
/// ```zig
/// _ = service.query(io, request);
/// ```
pub fn query(service: *Service, io: std.Io, request: QueryType) bool {
    return service.submit(io, .{ .query = request });
}

/// Samples lock-free service metrics without blocking history work.
///
/// ```zig
/// const stats = service.statsSnapshot();
/// ```
pub fn statsSnapshot(service: *const Service) SnapshotType {
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
