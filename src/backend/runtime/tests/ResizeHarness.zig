const ResizeHarness = @This();
const Trace = @import("Trace.zig");
const GeometryCapture = @import("GeometryCapture.zig");
const SchedulerCapture = @import("SchedulerCapture.zig");
const pane_resize_commands = @import("../application/commands/pane_resize.zig");
const source_namespace = @import("pane_resize_test.zig");
trace: Trace = .{},
geometry: GeometryCapture = undefined,
scheduler: SchedulerCapture = undefined,
handler: pane_resize_commands.PaneResizeHandler = undefined,

pub fn init(harness: *ResizeHarness, attachments: *source_namespace.AttachmentStore, expected_size: source_namespace.schema.TerminalSize) void {
    harness.trace = .{};
    harness.geometry = .{ .trace = &harness.trace, .attachments = attachments };
    harness.scheduler = .{
        .trace = &harness.trace,
        .attachments = attachments,
        .expected_size = expected_size,
    };
    harness.handler = .{
        .attachments = attachments,
        .geometry = harness.geometry.lease(),
        .scheduler = harness.scheduler.scheduler(),
    };
}
