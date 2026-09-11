const Controller = @This();
const source_namespace = @import("prune_history.zig");
const history_mod = @import("../../../history/root.zig");
const std = @import("std");
responses: *source_namespace.ResponseQueue,
service: *history_mod.Service,

/// Creates a controller scoped to one delete or prune request.
///
/// ```zig
/// var controller = Controller.init(&responses, application.history_service);
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, service: *history_mod.Service) Controller {
    return .{ .responses = responses, .service = service };
}

/// Queues one exact-entry deletion for the worker.
///
/// ```zig
/// try controller.deleteHistory(io, origin, request);
/// ```
pub fn deleteHistory(controller: *Controller, context: DeleteContext) !void {
    if (!controller.service.deleteHistory(context.io, .{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .id = context.request.id,
    })) {
        try controller.refuse(context.request.request_id);
    }
}

/// Validates and queues one bounded prune for the worker.
///
/// ```zig
/// try controller.pruneHistory(io, origin, request);
/// ```
pub fn pruneHistory(controller: *Controller, context: PruneContext) !void {
    const prune = history_mod.model.Prune.init(.{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .scope = context.request.scope,
        .scope_value = context.request.scope_value,
        .pane_id = context.request.pane_id,
        .before_ms = context.request.before_ms,
        .failed_only = context.request.failed_only,
        .match = context.request.match,
    }) catch {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .invalid_request,
            .message = "invalid history prune",
        } });
        return;
    };

    if (!controller.service.pruneHistory(context.io, prune)) {
        try controller.refuse(context.request.request_id);
    }
}

pub const DeleteContext = struct {
    io: std.Io,
    origin: source_namespace.QueryOrigin,
    request: source_namespace.schema.DeleteHistory,
};

pub const PruneContext = struct {
    io: std.Io,
    origin: source_namespace.QueryOrigin,
    request: source_namespace.schema.PruneHistory,
};

fn refuse(controller: *Controller, request_id: source_namespace.schema.RequestId) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .resource_limit,
        .message = "history queue is full",
    } });
}
