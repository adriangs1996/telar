const PaneRefType = @import("PaneRef.zig");
/// The runtime socket and the pane generation a hook reports for.
const Target = @This();

socket: ?[*:0]const u8,
pane: PaneRefType,
