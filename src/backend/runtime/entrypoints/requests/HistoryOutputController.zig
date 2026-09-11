const ReadContextType = @import("ReadContext.zig");
const StatsContextType = @import("StatsContext.zig");
const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ServiceType = @import("../../../history/Service.zig");
const StatsQueryType = @import("../../../history/StatsQuery.zig");
const Controller = @This();

responses: *ResponseQueueType,
service: *ServiceType,

/// Creates a controller scoped to one output read.
///
/// ```zig
/// var controller = Controller.init(&responses, application.history_service);
/// ```
pub fn init(responses: *ResponseQueueType, service: *ServiceType) Controller {
    return .{ .responses = responses, .service = service };
}

/// Queues one captured-output read for the worker.
///
/// ```zig
/// try controller.readHistoryOutput(context);
/// ```
pub fn readHistoryOutput(controller: *Controller, context: ReadContextType) !void {
    if (!controller.service.readOutput(context.io, .{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .id = context.request.id,
    })) {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .resource_limit,
            .message = "history queue is full",
        } });
    }
}

/// Queues one stats aggregation for the worker.
///
/// ```zig
/// try controller.historyStats(context);
/// ```
pub fn historyStats(controller: *Controller, context: StatsContextType) !void {
    const query = StatsQueryType.init(.{
        .request_id = context.request.request_id,
        .origin = context.origin,
        .scope = context.request.scope,
        .scope_value = context.request.scope_value,
        .pane_id = context.request.pane_id,
        .since_ms = context.request.since_ms,
    }) catch {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .invalid_request,
            .message = "invalid history stats query",
        } });
        return;
    };

    if (!controller.service.statsHistory(context.io, query)) {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = context.request.request_id,
            .code = .resource_limit,
            .message = "history queue is full",
        } });
    }
}

pub const ReadContext = @import("ReadContext.zig");

pub const StatsContext = @import("StatsContext.zig");
