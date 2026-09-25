const std = @import("std");
const core = @import("telar-core");
const RequestFixture = @import("RequestFixture.zig");
const RuntimeModel = @import("../RuntimeModel.zig");
const pane_attachment = @import("../pane_attachment.zig");
const Pane = @import("../../pane/Pane.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const pty = @import("pty");
const Command = pty.Command;
const event = @import("../event.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const ObservationCompletion = @import("../events/ObservationCompletion.zig");
const EventFixture = @This();

request: RequestFixture,
model: *RuntimeModel,
pane: *Pane,
metrics: *RuntimeMetrics,
unavailable: std.Io.Select(event.Event),
unavailable_storage: [1]event.Event,

/// Creates runtime-owned resources and a real child without scheduling pane actors.
/// Tests can acquire each borrow explicitly before delivering its completion.
/// Example: `var fixture: EventFixture = undefined; try fixture.init();`.
pub fn init(self: *EventFixture) !void {
    try self.request.init();
    errdefer self.request.deinit();
    self.model = &self.request.runtime.model;
    self.metrics = &self.model.metrics;
    self.unavailable = .init(std.Io.failing, &self.unavailable_storage);
    const arguments = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try Command.fromArgv(&arguments);
    self.pane = try Pane.create(.{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .history_service = self.model.resources.history.service(),
        .graphics_budget = &self.model.panes.graphics_budget,
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
    self.model.panes.insert(self.pane) catch |err| {
        self.pane.session.shutdown();
        self.pane.destroy();
        return err;
    };
    _ = try pane_attachment.attach(self.model, self.request.session, self.pane);
}

pub fn deinit(self: *EventFixture) void {
    self.model.select = self.request.runtime.loop.selector();
    self.request.deinit();
}

/// Rejects actor admission at std.Io, preserving production rollback policy.
/// Example: `fixture.failScheduling();`.
pub fn failScheduling(self: *EventFixture) void {
    self.model.select = &self.unavailable;
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
