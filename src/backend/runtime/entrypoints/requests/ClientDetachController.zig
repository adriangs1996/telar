const core = @import("telar-core");
const Session = @import("../../client/Session.zig");
const Handler = @import("../../application/commands/ClientDetachHandler.zig");
const Controller = @This();

handler: Handler,
session: *Session,

/// Admits teardown only from a separate control connection. Example: `try controller.detach(request);`
pub fn detach(self: *Controller, request: core.DetachClient) !void {
    if (self.session.role != .control or self.session.key.id == request.client_id) {
        return self.reject(request.request_id);
    }

    self.handler.execute(.{ .id = request.client_id, .generation = request.client_generation }) catch {
        return self.reject(request.request_id);
    };
    try self.session.delivery.responses.push(.{ .request_completed = .{ .request_id = request.request_id } });
}

fn reject(self: *Controller, request_id: core.RequestId) !void {
    try self.session.delivery.responses.push(.{ .request_failed = .{ .request_id = request_id, .code = .invalid_request, .message = "interactive client is absent, closing, or its generation is stale" } });
}
