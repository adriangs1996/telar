//! Hit-test projection for pane content rendered by the multiplexer.

const data = @import("model");
const ContextType = @import("Context.zig");

pub fn register(context: *ContextType, snapshot: *const data.LayoutSnapshot) void {
    for (snapshot.views()) |view| {
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
    }
}
