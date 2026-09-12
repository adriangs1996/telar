const Fixture = @import("Fixture.zig");
const FrameViewType = @import("telar-core").FrameView;
const types = @import("../model/types.zig");
const ApplyPaneFrameHandlerType = @import("../application/panes/ApplyPaneFrameHandler.zig");
const Frames = @This();

pub fn apply(fixture: *Fixture, frame: FrameViewType) !types.PaneFrameOutcome {
    var handler: ApplyPaneFrameHandlerType = .{
        .model = &fixture.model,
        .effects = .{ .context = fixture, .recover = Fixture.recover, .acknowledge = Fixture.acknowledge, .deliver = Fixture.frameResources },
    };
    return handler.execute(frame);
}
