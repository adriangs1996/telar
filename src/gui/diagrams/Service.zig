//! The GUI owns all worker output, even if shutdown drops its inbox notification.
const std = @import("std");
const Service = @This();

store: @import("Store.zig"),
job: ?@import("Job.zig") = null,
result: ?@import("Completion.zig") = null,
notified: bool = false,

/// Example: `var service = Service.init(allocator);`
pub fn init(allocator: std.mem.Allocator) Service {
    return .{ .store = .init(allocator) };
}

/// Call only after the inbox has cancelled and joined its producers.
/// Example: `service.deinit();`
pub fn deinit(service: *Service) void {
    if (service.result) |completion| {
        if (completion.result) |value| {
            var image = value;
            image.deinit(service.store.allocator);
        } else |_| {}
    }
    service.store.deinit();
}

/// Frame preparation adopts completed pixels only after the prior flight ends.
/// Example: `service.beginFrame();`
pub fn beginFrame(service: *Service) void {
    service.store.beginFrame();
    if (service.notified) {
        _ = service.store.finish(service.result.?);
        service.result = null;
        service.job = null;
        service.notified = false;
    }
}

/// Admits visible requests only after measuring and painting have finished.
/// Example: `service.start(&loop.inbox);`
pub fn start(service: *Service, inbox: *@import("../gui_event.zig").Inbox) void {
    const job = service.store.nextJob() orelse return;
    service.job = job;
    inbox.start(.diagram_ready, .{ execute, .{ service, inbox.io } }) catch {
        _ = service.store.finish(.{ .id = job.id, .result = error.RendererUnavailable });
        service.job = null;
    };
}

/// The inbox's publish/consume synchronization makes the worker result visible.
/// Example: `service.notify();`
pub fn notify(service: *Service) void {
    service.notified = true;
}

/// Runs on the inbox worker and publishes only a void completion notification.
/// Example: `try inbox.start(.diagram_ready, .{ Service.execute, .{ service, io } });`
pub fn execute(service: *Service, io: std.Io) void {
    const job = &service.job.?;
    service.result = .{ .id = job.id, .result = @import("worker.zig").render(io, service.store.allocator, job) };
}
