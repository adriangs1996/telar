//! Hit-test projection for pane content rendered by the multiplexer.

const layout = @import("../workspace/root.zig").layout;
const widget = @import("context.zig");

pub fn register(context: *widget.Context, snapshot: *const layout.Snapshot) void {
    for (snapshot.views()) |view| {
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
    }
}
