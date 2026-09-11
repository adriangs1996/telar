const id = @import("id.zig");
const Cursor = @import("Cursor.zig");
const Mouse = @import("Mouse.zig");
const InputModes = @import("InputModes.zig");
const frame_support = @import("frame_support.zig");
const Scroll = @import("Scroll.zig");
const Span = @import("Span.zig");
const Frame = @This();

pane_id: id.PaneId,
frame_id: u64,
/// Zero denotes a full snapshot. A patch names the last acknowledged frame
/// it was computed from.
base_frame_id: u64,
cols: u16,
rows: u16,
cursor: Cursor = .{},
mouse: Mouse = .{},
input_modes: InputModes = .{},
pointer_shape: frame_support.PointerShape = .default,
scroll: Scroll,
spans: []const Span,
