/// The runtime socket and the pane generation a hook reports for.
const Target = @This();
const control = @import("control.zig");
socket: ?[*:0]const u8,
pane: control.Session.PaneRef,
