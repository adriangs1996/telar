//! Request-scoped controller for bounded history imports.

const std = @import("std");
const core = @import("telar-core");
const history_mod = @import("../../../history/root.zig");
const delivery_mod = @import("../../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Controller = struct {
    responses: *ResponseQueue,
    service: *history_mod.Service,

    /// Creates a controller scoped to one import batch.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, application.history_service);
    /// ```
    pub fn init(responses: *ResponseQueue, service: *history_mod.Service) Controller {
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
    pub fn importHistory(controller: *Controller, io: std.Io, batch: schema.ImportHistoryView) !void {
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
};

test "Controller acknowledges an accepted batch" {
    const gpa = std.testing.allocator;
    var responses: ResponseQueue = .{};
    var service = try history_mod.Service.init(gpa, .{ .database_path = ":memory:" });
    defer {
        service.stop(std.testing.io);
        service.deinit(std.testing.io);
    }
    var controller = Controller.init(&responses, &service);

    var buffer: [512]u8 = undefined;
    const entries = [_]schema.ImportEntry{
        .{ .started_at_ms = 1_000, .command = "git status" },
    };
    const encoded = try schema.encodeImportHistory(&buffer, .{
        .request_id = @enumFromInt(5),
        .source = "zsh:/tmp/histfile",
        .base_sequence = 0,
        .entries = &entries,
    });
    const view = (try schema.decodeClient(encoded)).import_history;

    try controller.importHistory(std.testing.io, view);

    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(responses.items[0].request_completed.request_id));
}
