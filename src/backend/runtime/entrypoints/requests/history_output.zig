//! Request-scoped controller for captured-output reads, answered
//! asynchronously by the history worker.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const delivery_mod = @import("../../delivery/root.zig");

const schema = core.schema;
const QueryOrigin = history_mod.model.QueryOrigin;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    service: *history_mod.Service,

    /// Creates a controller scoped to one output read.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, application.history_service);
    /// ```
    pub fn init(responses: *ResponseQueue, service: *history_mod.Service) Controller {
        return .{ .responses = responses, .service = service };
    }

    /// Queues one captured-output read for the worker.
    ///
    /// ```zig
    /// try controller.readHistoryOutput(context);
    /// ```
    pub fn readHistoryOutput(controller: *Controller, context: ReadContext) !void {
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

    pub const ReadContext = struct {
        io: std.Io,
        origin: QueryOrigin,
        request: schema.ReadHistoryOutput,
    };
};
