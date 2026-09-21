const core = @import("telar-core");
const Application = @import("../../application/Application.zig");
const Session = @import("../../client/Session.zig");
const Handler = @import("../../application/commands/EditorOpenHandler.zig");
const Job = @import("../../../editors/Job.zig");
const Controller = @This();

application: *Application,
session: *Session,

/// Translates admission failures without blocking the requesting client.
/// Example: `try controller.handle(request);`
pub fn handle(self: *Controller, message: core.OpenEditor) !void {
    const handler: Handler = .{ .application = self.application };
    handler.execute(.{ .client = self.session.key, .message = message }) catch |err| {
        try self.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = message.request_id,
            .code = switch (err) {
                error.PaneNotFound => .pane_not_found,
                error.PaneExited => .pane_exited,
                error.EditorOpenBusy => .resource_limit,
                else => .internal,
            },
            .message = "Could not request editor reuse",
        } });
    };
}

/// Delivers only to the original connection generation. Example: `Controller.complete(application, job);`
pub fn complete(application: *Application, job: *Job) void {
    const handler: Handler = .{ .application = application };
    const result = handler.complete(job);
    const client = application.clients.resolve(job.client) orelse return;
    if (!client.active()) {
        return;
    }

    client.delivery.responses.push(.{ .editor_opened = result }) catch {
        application.dropClient(job.client);
        return;
    };
    application.pumpAll();
}
