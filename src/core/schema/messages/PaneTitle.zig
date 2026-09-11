const id = @import("../id.zig");
/// The child's window title as last set through OSC 0 or OSC 2. An empty
/// title means the child cleared it.
const PaneTitle = @This();

pane_id: id.PaneId,
title: []const u8,
