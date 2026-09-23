//! Runtime history operations, reached from requests.dispatch.

const core = @import("telar-core");
const DeleteContextType = @import("../../entrypoints/requests/DeleteContext.zig");
const PruneContextType = @import("../../entrypoints/requests/PruneContext.zig");
const PruneType = @import("../../../history/Prune.zig");
const ReadContextType = @import("../../entrypoints/requests/ReadContext.zig");
const StatsContextType = @import("../../entrypoints/requests/StatsContext.zig");
const StatsQueryType = @import("../../../history/StatsQuery.zig");
const HistoryRequest = @import("../queries/HistoryRequest.zig");
const HistoryQueryFailure = @import("../../entrypoints/requests/HistoryQueryFailure.zig");
const std = @import("std");
const QueryType = @import("../../../history/Query.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try history.routeQueryHistory(request, wire);`.
pub fn routeQueryHistory(request: *RequestContext, wire: core.QueryHistory) !void {
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
            if (comptime core.enabled) {
                request.model.metrics.history_query_failures += 1;
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

    if (comptime core.enabled) {
        request.model.metrics.history_queries += 1;
    }
}

/// Example: `try history.routeDeleteHistory(request, delete);`.
pub fn routeDeleteHistory(request: *RequestContext, delete: core.DeleteHistory) !void {
    try historyDeleteHistory(request, .{
        .io = request.model.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = delete,
    });
}

/// Example: `try history.routePruneHistory(request, prune);`.
pub fn routePruneHistory(request: *RequestContext, prune: core.PruneHistory) !void {
    try historyPruneHistory(request, .{
        .io = request.model.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = prune,
    });
}

/// Example: `try history.routeReadHistoryOutput(request, read);`.
pub fn routeReadHistoryOutput(request: *RequestContext, read: core.ReadHistoryOutput) !void {
    try historyReadHistoryOutput(request, .{
        .io = request.model.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = read,
    });
}

/// Example: `try history.routeHistoryStats(request, query);`.
pub fn routeHistoryStats(request: *RequestContext, query: core.HistoryStatsQuery) !void {
    try historyHistoryStats(request, .{
        .io = request.model.io,
        .origin = .{
            .client = request.session.key,
            .close_after_reply = request.session.role == .control,
        },
        .request = query,
    });
}

/// Example: `try history.routeImportHistory(request, batch);`.
pub fn routeImportHistory(request: *RequestContext, batch: core.ImportHistoryView) !void {
    try historyImportHistory(request, request.model.io, batch);
}

fn queryHistory(request: *RequestContext, command: HistoryRequest) anyerror!void {
    const model = request.model;

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

    if (!model.resources.history.service().query(model.io, query)) {
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
    if (!request.model.resources.history.service().deleteHistory(context.io, .{
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

    if (!request.model.resources.history.service().pruneHistory(context.io, prune)) {
        try historyRefuse(request, context.request.request_id);
    }
}

fn historyRefuse(request: *RequestContext, request_id: core.RequestId) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .resource_limit,
        .message = "history queue is full",
    } });
}

fn historyReadHistoryOutput(request: *RequestContext, context: ReadContextType) !void {
    if (!request.model.resources.history.service().readOutput(context.io, .{
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

    if (!request.model.resources.history.service().statsHistory(context.io, query)) {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .resource_limit,
            .message = "history queue is full",
        } });
    }
}

fn historyImportHistory(request: *RequestContext, io: std.Io, batch: core.ImportHistoryView) !void {
    if (!request.model.resources.history.service().importBatch(io, batch)) {
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
