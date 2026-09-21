const std = @import("std");
const core = @import("telar-core");
const RequestFixture = @import("RequestFixture.zig");
const Application = @import("../application/Application.zig");
const Pane = @import("../../pane/Pane.zig");
const Tracker = @import("../../agent/Tracker.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Command = @import("../../pty/Command.zig");
const event = @import("../event.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const ObservationCompletion = @import("../entrypoints/events/pane/ObservationCompletion.zig");
const EventFixture = @This();

request: RequestFixture,
application: *Application,
pane: *Pane,
agents: *Tracker,
metrics: *RuntimeMetrics,
unavailable: std.Io.Select(event.Event),
unavailable_storage: [1]event.Event,

/// Creates runtime-owned resources and a real child without scheduling pane actors.
/// Tests can acquire each borrow explicitly before delivering its completion.
/// Example: `var fixture: EventFixture = undefined; try fixture.init();`.
pub fn init(self: *EventFixture) !void {
    try self.request.init();
    errdefer self.request.deinit();
    self.application = &self.request.runtime.application;
    self.agents = &self.application.model.agents;
    self.metrics = &self.application.metrics;
    self.unavailable = .init(std.Io.failing, &self.unavailable_storage);
    const arguments = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try Command.fromArgv(&arguments);
    self.pane = try Pane.create(.{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .history_service = self.application.history_service,
        .graphics_budget = &self.application.model.panes.graphics_budget,
    }, .{
        .identity = .{ .id = @enumFromInt(7), .generation = 11 },
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(5) },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/work/telar",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    self.pane.commitLaunch("/bin/sleep");
    self.application.model.panes.insert(self.pane) catch |err| {
        self.pane.session.shutdown();
        self.pane.destroy();
        return err;
    };
    _ = try self.request.session.attachments.attach(std.testing.allocator, self.pane);
}

pub fn deinit(self: *EventFixture) void {
    self.application.select = self.request.runtime.loop.selector();
    self.request.deinit();
}

/// Rejects actor admission at std.Io, preserving production rollback policy.
/// Example: `fixture.failScheduling();`.
pub fn failScheduling(self: *EventFixture) void {
    self.application.select = &self.unavailable;
}

pub fn beginObservation(self: *EventFixture) !void {
    self.pane.queueHistoryOutput(.{ .bytes = "observed", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expect(self.pane.beginHistoryObservation() != null);
}

pub fn observed(self: *EventFixture, completion: ObservationCompletion) !void {
    try std.testing.expect(!try self.request.runtime.update(.{ .pane_observed = completion }));
}

pub fn sound(self: *EventFixture) ?core.AgentSoundNotification {
    const response = self.request.response() orelse return null;
    return switch (response.*) {
        .agent_sound => |value| value,
        else => null,
    };
}
