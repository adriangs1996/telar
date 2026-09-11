const PaneIdType = @import("telar-core").PaneId;
const GraphicsCounts = @import("GraphicsCounts.zig");
const CommitEffect = @This();

detach_after_send: ?PaneIdType = null,
graphics_message: bool = false,
graphics: GraphicsCounts = .{ .images = 0, .placements = 0, .stage_blocked = 0, .adopted = 0, .freeze = .{} },
