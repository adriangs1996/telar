//! Reader status occupies the existing footer rather than obscuring selectable text.
const Status = @This();
bounds: @import("../render/Rect.zig"),
pane_id: @import("telar-core").PaneId,

/// Example: `try status.draw(canvas);`
pub fn draw(status: Status, canvas: *@import("Canvas.zig")) !void {
    const state = canvas.widgets orelse return;
    const selection = &state.thread_selection;
    const owner = selection.owner orelse return;
    if (owner.pane_id != status.pane_id) {
        return;
    }
    if (selection.dragging and selection.outside != 0 and !selection.blocked_edge) {
        if (canvas.animation) |clock| {
            clock.requestAt(selection.next_scroll_ns);
        }
    }
    const text = if (selection.problem) |problem| switch (problem) {
        .copy_limit => "Selection exceeds 64 KiB · select less text to copy",
        .copy_failed => "Could not copy · selection kept for retry",
        .geometry_limit => "Selection exceeds the visible text limit · reduce the selected area",
    } else if (selection.blocked_edge) "Clear selection with Esc to load more messages" else if (selection.keyboard) "Copy mode · arrows/hjkl · v select · y copy · Esc exit" else if (selection.selected()) "Text selected · Cmd/Ctrl+C copy · Esc clear" else return;
    var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label: @import("Label.zig") = .{ .text = text, .face = .sans, .size = .small, .color = if (selection.problem != null or selection.blocked_edge) canvas.theme.palette.yellow else canvas.theme.palette.subtext0 };
    label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = status.bounds.width }).fit(label, &storage);
    _ = try canvas.textAt(status.bounds, label);
}
