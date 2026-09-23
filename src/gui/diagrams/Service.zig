//! The GUI owns all worker output, even if shutdown drops its inbox notification.
const gui_event = @import("../gui_event.zig");
const worker = @import("worker.zig");
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
pub fn deinit(self: *Service) void {
    if (self.result) |completion| {
        if (completion.result) |value| {
            var image = value;
            image.deinit(self.store.allocator);
        } else |_| {}
    }
    self.store.deinit();
}

/// Frame preparation adopts completed pixels only after the prior flight ends.
/// Example: `service.beginFrame();`
pub fn beginFrame(self: *Service) void {
    self.store.beginFrame();
    if (self.notified) {
        _ = self.store.finish(self.result.?);
        self.result = null;
        self.job = null;
        self.notified = false;
    }
}

/// Admits visible requests only after measuring and painting have finished.
/// Example: `service.start(&loop.inbox);`
pub fn start(self: *Service, inbox: *gui_event.Inbox) void {
    const job = self.store.nextJob() orelse return;
    self.job = job;
    inbox.start(.diagram_ready, .{ execute, .{ self, inbox.io } }) catch {
        _ = self.store.finish(.{ .id = job.id, .result = error.RendererUnavailable });
        self.job = null;
    };
}

/// The inbox's publish/consume synchronization makes the worker result visible.
/// Example: `service.notify();`
pub fn notify(self: *Service) void {
    self.notified = true;
}

/// Runs on the inbox worker and publishes only a void completion notification.
/// Example: `try inbox.start(.diagram_ready, .{ Service.execute, .{ service, io } });`
pub fn execute(self: *Service, io: std.Io) void {
    const job = &self.job.?;
    self.result = .{ .id = job.id, .result = worker.render(io, self.store.allocator, job) };
}
