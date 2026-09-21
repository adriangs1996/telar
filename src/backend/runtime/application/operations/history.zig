//! Runtime history operations, reached from requests.dispatch.

const DeleteContextType = @import("../../entrypoints/requests/DeleteContext.zig");
const PruneContextType = @import("../../entrypoints/requests/PruneContext.zig");
const PruneType = @import("../../../history/Prune.zig");
const ReadContextType = @import("../../entrypoints/requests/ReadContext.zig");
const StatsContextType = @import("../../entrypoints/requests/StatsContext.zig");
const StatsQueryType = @import("../../../history/StatsQuery.zig");
const HistoryRequest = @import("../queries/HistoryRequest.zig");
const enabled_module = @import("telar-core").enabled;
const HistoryQueryFailure = @import("../../entrypoints/requests/HistoryQueryFailure.zig");
const QueryHistoryType = @import("telar-core").QueryHistory;
const RequestIdType = @import("telar-core").RequestId;
const DeleteHistoryType = @import("telar-core").DeleteHistory;
const PruneHistoryType = @import("telar-core").PruneHistory;
const ReadHistoryOutputType = @import("telar-core").ReadHistoryOutput;
const HistoryStatsQueryType = @import("telar-core").HistoryStatsQuery;
const ImportHistoryViewType = @import("telar-core").ImportHistoryView;
const std = @import("std");
const QueryType = @import("../../../history/Query.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try history.routeQueryHistory(request, wire);`.
pub fn routeQueryHistory(request: *RequestContext, wire: QueryHistoryType) !void {
    queryHistory(request, .{
        .request_id = wire.request_id,
        .origin = .{ .client = request.session.key, .close_after_reply = request.session.role == .control },
        .text = wire.query,
        .scope = wire.scope,
        .scope_value = wire.scope_value,
        .pane_id = wire.pane_id,
        .failed_only = wire.failed_only,
        .author = wire.author,
        .match = wire.match,
        .distinct = wire.distinct,
        .limit = wire.limit,
        .offset = wire.offset,
        .snapshot_id = wire.snapshot_id,
        .entry_id = wire.entry_id,
    }) catch |err| switch (err) {
        error.InvalidHistoryQuery => {
            try queryHistoryQueueFailure(request, .{
                .request_id = wire.request_id,
                .code = .invalid_request,
                .message = "invalid history query",
            });
            return;
        },
        error.HistoryQueueFull => {
            if (comptime enabled_module) {
                request.application.metrics.history_query_failures += 1;
            }

            try queryHistoryQueueFailure(request, .{
                .request_id = wire.request_id,
                .code = .resource_limit,
                .message = "history queue is full",
            });
            return;
        },
        else => return err,
    };

    if (comptime enabled_module) {
        request.application.metrics.history_queries += 1;
    }
}

/// Example: `try history.routeDeleteHistory(request, delete);`.
pub fn routeDeleteHistory(request: *RequestContext, delete: DeleteHistoryType) !void {
    try historyDeleteHistory(request, .{
        .io = request.application.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = delete,
    });
}

/// Example: `try history.routePruneHistory(request, prune);`.
pub fn routePruneHistory(request: *RequestContext, prune: PruneHistoryType) !void {
    try historyPruneHistory(request, .{
        .io = request.application.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = prune,
    });
}

/// Example: `try history.routeReadHistoryOutput(request, read);`.
pub fn routeReadHistoryOutput(request: *RequestContext, read: ReadHistoryOutputType) !void {
    try historyReadHistoryOutput(request, .{
        .io = request.application.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = read,
    });
}

/// Example: `try history.routeHistoryStats(request, query);`.
pub fn routeHistoryStats(request: *RequestContext, query: HistoryStatsQueryType) !void {
    try historyHistoryStats(request, .{
        .io = request.application.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = query,
    });
}

/// Example: `try history.routeImportHistory(request, batch);`.
pub fn routeImportHistory(request: *RequestContext, batch: ImportHistoryViewType) !void {
    try historyImportHistory(request, request.application.io, batch);
}

fn queryHistory(request: *RequestContext, command: HistoryRequest) anyerror!void {
    const application = request.application;

    const query = QueryType.init(.{
        .request_id = command.request_id,
        .origin = command.origin,
        .text = command.text,
        .scope = command.scope,
        .scope_value = command.scope_value,
        .pane_id = command.pane_id,
        .failed_only = command.failed_only,
        .author = command.author,
        .match = command.match,
        .distinct = command.distinct,
        .limit = command.limit,
        .offset = command.offset,
        .snapshot_id = command.snapshot_id,
        .entry_id = command.entry_id,
    }) catch {
        return error.InvalidHistoryQuery;
    };

    if (!application.history_service.query(application.io, query)) {
        return error.HistoryQueueFull;
    }
}

fn queryHistoryQueueFailure(request: *RequestContext, failure: HistoryQueryFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = failure.request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn historyDeleteHistory(request: *RequestContext, context: DeleteContextType) !void {
    if (!request.application.history_service.deleteHistory(context.io, .{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .id = context.request.id,
    })) {
        try historyRefuse(request, context.request.request_id);
    }
}

fn historyPruneHistory(request: *RequestContext, context: PruneContextType) !void {
    const prune = PruneType.init(.{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .scope = context.request.scope,
        .scope_value = context.request.scope_value,
        .pane_id = context.request.pane_id,
        .before_ms = context.request.before_ms,
        .failed_only = context.request.failed_only,
        .match = context.request.match,
    }) catch {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .invalid_request,
            .message = "invalid history prune",
        } });
        return;
    };

    if (!request.application.history_service.pruneHistory(context.io, prune)) {
        try historyRefuse(request, context.request.request_id);
    }
}

fn historyRefuse(request: *RequestContext, request_id: RequestIdType) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .resource_limit,
        .message = "history queue is full",
    } });
}

fn historyReadHistoryOutput(request: *RequestContext, context: ReadContextType) !void {
    if (!request.application.history_service.readOutput(context.io, .{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .id = context.request.id,
    })) {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .resource_limit,
            .message = "history queue is full",
        } });
    }
}

fn historyHistoryStats(request: *RequestContext, context: StatsContextType) !void {
    const query = StatsQueryType.init(.{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .scope = context.request.scope,
        .scope_value = context.request.scope_value,
        .pane_id = context.request.pane_id,
        .since_ms = context.request.since_ms,
    }) catch {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .invalid_request,
            .message = "invalid history stats query",
        } });
        return;
    };

    if (!request.application.history_service.statsHistory(context.io, query)) {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .resource_limit,
            .message = "history queue is full",
        } });
    }
}

fn historyImportHistory(request: *RequestContext, io: std.Io, batch: ImportHistoryViewType) !void {
    if (!request.application.history_service.importBatch(io, batch)) {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = batch.request_id,
            .code = .resource_limit,
            .message = "history import was not accepted",
        } });
        return;
    }

    try request.session.delivery.responses.push(.{ .request_completed = .{
        .request_id = batch.request_id,
    } });
}
