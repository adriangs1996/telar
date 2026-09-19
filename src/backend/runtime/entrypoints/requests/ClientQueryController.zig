const core = @import("telar-core");
const Handler = @import("../../application/commands/ClientListHandler.zig");
const ResponseQueue = @import("../../delivery/ResponseQueue.zig");
const Controller = @This();

handler: Handler,
responses: *ResponseQueue,

/// Correlates an owned client catalog with its requester. Example: `try controller.query(request);`
pub fn query(self: *Controller, request: core.QueryClients) !void {
    var result = self.handler.execute();
    result.request_id = request.request_id;
    try self.responses.push(.{ .client_list = result });
}
