//! One inbox observation task per GUI. Shutdown joins it before releasing state.
const gui_event = @import("../gui_event.zig");
const std = @import("std");
const Store = @import("Store.zig");
const Job = @import("Job.zig");
const Result = @import("Result.zig");
const DiffHighlighter = @import("DiffHighlighter.zig");
const Self = @This();

allocator: std.mem.Allocator,
store: Store = .{},
job: ?Job = null,
result: Result = .{},
notified: bool = false,

/// Adopts worker output after inbox synchronization, outside any GPU flight.
/// Example: `service.beginFrame();`
pub fn beginFrame(self: *Self) void {
    self.store.beginFrame();
    if (self.notified) {
        self.store.finish(&self.result);
        self.job = null;
        self.notified = false;
    }
}

/// Called after painting has submitted its bounded requests.
/// Example: `service.start(&loop.inbox);`
pub fn start(self: *Self, inbox: *gui_event.Inbox) void {
    if (self.job != null) {
        return;
    }

    self.job = self.store.nextJob() orelse return;
    inbox.start(.syntax_ready, .{ execute, .{ self, inbox.io } }) catch {
        self.result.id = self.job.?.id;
        self.result.status = error.SyntaxUnavailable;
        self.store.finish(&self.result);
        self.job = null;
    };
}

pub fn notify(self: *Self) void {
    self.notified = true;
}

/// Worker-only entrypoint; the inbox publishes completion after this returns.
/// Example: `service.execute(io);`
pub fn execute(self: *Self, io: std.Io) void {
    const job = &self.job.?;
    self.result.id = job.id;
    var worker: DiffHighlighter = .{ .allocator = self.allocator, .io = io, .text = job.source[0..job.len], .roles = self.result.roles[0..job.len] };
    self.result.status = worker.run();
}
