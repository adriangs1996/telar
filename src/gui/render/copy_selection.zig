//! Copy mode is a disposable visual projection; canonical cells stay untouched.
const client = @import("telar-client");
const core = @import("telar-core");

/// Example: `const selection = copy_selection.forPane(projection.copy, pane.id);`
pub fn forPane(projection: ?client.CopyProjection, id: core.PaneId) ?client.CopyModeView {
    const copy = projection orelse return null;
    return if (copy.pane_id == id) copy.view else null;
}

/// Resolves keyboard copy position from absolute scrollback to the visible frame.
/// Example: `const cursor = copy_selection.cursor(pane, selection);`
pub fn cursor(pane: *const client.Pane, selection: ?client.CopyModeView) core.Cursor {
    const copy = selection orelse return pane.cursor;
    if (copy.pointer) {
        return pane.cursor;
    }

    if (copy.cursor.y < pane.scroll.offset or copy.cursor.y - pane.scroll.offset >= pane.buffer.h) {
        return .{};
    }

    return .{
        .x = copy.cursor.x,
        .y = @intCast(copy.cursor.y - pane.scroll.offset),
        .visible = true,
        .appearance = .{ .shape = .block, .blink = false },
    };
}
