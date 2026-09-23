//! Hit-test projection for pane content rendered by the multiplexer.

const data = @import("model");
const Context = @import("Context.zig");

pub fn register(context: *Context, snapshot: *const data.LayoutSnapshot) void {
    for (snapshot.views()) |view| {
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
    }
}
