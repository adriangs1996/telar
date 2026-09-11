const Controller = @This();
const source_namespace = @import("import_history.zig");
const history_mod = @import("../../../history/root.zig");
const std = @import("std");
responses: *source_namespace.ResponseQueue,
service: *history_mod.Service,

/// Creates a controller scoped to one import batch.
///
/// ```zig
/// var controller = Controller.init(&responses, application.history_service);
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, service: *history_mod.Service) Controller {
    return .{ .responses = responses, .service = service };
}

/// Copies the batch into the bounded history queue and acknowledges it.
/// The acknowledgement means the batch was accepted, not that it is
/// durable yet: imports share the fire-and-forget write contract that
/// live command captures use.
///
/// ```zig
/// try controller.importHistory(io, batch);
/// ```
pub fn importHistory(controller: *Controller, io: std.Io, batch: source_namespace.schema.ImportHistoryView) !void {
    if (!controller.service.importBatch(io, batch)) {
        try controller.responses.push(.{ .request_failed = .{
            .request_id = batch.request_id,
            .code = .resource_limit,
            .message = "history import was not accepted",
        } });
        return;
    }

    try controller.responses.push(.{ .request_completed = .{
        .request_id = batch.request_id,
    } });
}
