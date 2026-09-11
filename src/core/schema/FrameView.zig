const FrameView = @This();
const id = @import("id.zig");
const Cursor = @import("Cursor.zig");
const Mouse = @import("Mouse.zig");
const InputModes = @import("InputModes.zig");
const source_namespace = @import("frame_support.zig");
const Scroll = @import("Scroll.zig");
const SpanIterator = @import("SpanIterator.zig");
pane_id: id.PaneId,
frame_id: u64,
base_frame_id: u64,
cols: u16,
rows: u16,
cursor: Cursor,
mouse: Mouse,
input_modes: InputModes,
pointer_shape: source_namespace.PointerShape = .default,
scroll: Scroll,
span_count: u16,
encoded_spans: []const u8,

pub fn isSnapshot(frame: FrameView) bool {
    return frame.base_frame_id == 0;
}

pub fn spans(frame: FrameView) SpanIterator {
    return .{
        .decoder = .init(frame.encoded_spans),
        .remaining = frame.span_count,
    };
}
