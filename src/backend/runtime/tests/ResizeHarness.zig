const Trace = @import("Trace.zig");
const GeometryCapture = @import("GeometryCapture.zig");
const SchedulerCapture = @import("SchedulerCapture.zig");
const PaneResizeHandlerType = @import("../application/commands/PaneResizeHandler.zig");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ResizeHarness = @This();

trace: Trace = .{},
geometry: GeometryCapture = undefined,
scheduler: SchedulerCapture = undefined,
handler: PaneResizeHandlerType = undefined,

pub fn init(harness: *ResizeHarness, attachments: *AttachmentStoreType, expected_size: TerminalSizeType) void {
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
