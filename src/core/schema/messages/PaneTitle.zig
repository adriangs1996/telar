/// The child's window title as last set through OSC 0 or OSC 2. An empty
/// title means the child cleared it.
const PaneTitle = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
title: []const u8,
