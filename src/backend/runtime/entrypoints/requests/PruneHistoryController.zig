const DeleteContextType = @import("DeleteContext.zig");
const PruneContextType = @import("PruneContext.zig");
const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ServiceType = @import("../../../history/Service.zig");
const PruneType = @import("../../../history/Prune.zig");
const RequestIdType = @import("telar-core").RequestId;
const Controller = @This();

responses: *ResponseQueueType,
service: *ServiceType,

/// Creates a controller scoped to one delete or prune request.
///
/// ```zig
/// var controller = Controller.init(&responses, application.history_service);
/// ```
pub fn init(responses: *ResponseQueueType, service: *ServiceType) Controller {
    return .{ .responses = responses, .service = service };
}

/// Queues one exact-entry deletion for the worker.
///
/// ```zig
/// try controller.deleteHistory(io, origin, request);
/// ```
pub fn deleteHistory(controller: *Controller, context: DeleteContextType) !void {
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
pub fn pruneHistory(controller: *Controller, context: PruneContextType) !void {
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

pub const DeleteContext = @import("DeleteContext.zig");

pub const PruneContext = @import("PruneContext.zig");

fn refuse(controller: *Controller, request_id: RequestIdType) !void {
    try controller.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .resource_limit,
        .message = "history queue is full",
    } });
}
