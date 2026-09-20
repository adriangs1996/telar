const core = @import("telar-core");
const Session = @import("../../client/Session.zig");
const Handler = @import("../../application/commands/ClientCommandHandler.zig");
const Controller = @This();
handler: Handler,
session: *Session,

/// Maps admission failures into correlated protocol failures. Example: `try controller.request(command);`
pub fn request(self: *Controller, command: core.ClientCommand) !void {
    self.handler.request(self.session, command) catch |err| {
        try self.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = command.request_id,
            .code = .invalid_request,
            .message = @errorName(err),
        } });
    };
}

/// Delegates a UI completion. Example: `try controller.complete(reply);`
pub fn complete(self: *Controller, command: core.ClientCommand) !void {
    try self.handler.complete(self.session, command);
}
