const Frames = @This();
const Fixture = @import("Fixture.zig");
const source_namespace = @import("headless_tests.zig");
const client = @import("../root.zig");
pub fn apply(fixture: *Fixture, frame: source_namespace.schema.frame.FrameView) !client.model.PaneFrameOutcome {
    var handler: source_namespace.app.panes.pane_frame.ApplyPaneFrameHandler = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .recover = Fixture.recover, .deliver = Fixture.frameResources },
    };
    return handler.execute(frame);
}
