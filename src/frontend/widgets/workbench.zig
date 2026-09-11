//! Hit-test projection for pane content rendered by the multiplexer.

const ContextType = @import("Context.zig");
const LayoutSnapshot = @import("telar-client").LayoutSnapshot;

pub fn register(context: *ContextType, snapshot: *const LayoutSnapshot) void {
    for (snapshot.views()) |view| {
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
    }
}
