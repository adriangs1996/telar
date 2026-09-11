const std = @import("std");
const PaneType = @import("../../../../pane/Pane.zig");
/// Output-read borrow handed to the runtime actor scheduler.
const Read = @This();

io: std.Io,
pane: *PaneType,
