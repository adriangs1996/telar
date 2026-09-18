//! Text highlighting shares the exact fragment geometry used for hit testing.
const Canvas = @import("Canvas.zig");
const Fragment = @import("interaction/ThreadTextFragment.zig");
const Geometry = @import("interaction/ThreadTextGeometry.zig");
const Paint = @This();
geometry: *const Geometry,
fragment: Fragment,

/// Example: `try (ThreadTextPaint{ .geometry = geometry, .fragment = fragment }).draw(canvas);`
pub fn draw(paint: Paint, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    const selection = &state.thread_selection;
    const fragment = paint.fragment;
    const row = paint.geometry.rows[fragment.row];
    const owner = selection.owner orelse return;
    if (owner.pane_id != row.owner.pane_id or owner.attachment_generation != row.owner.attachment_generation) {
        return;
    }
    const first = canvas.quads.items().len;
    const left_clip = @max(fragment.bounds.x, fragment.clip.x);
    const top_clip = @max(fragment.bounds.y, fragment.clip.y);
    const right_clip = @min(fragment.bounds.x + fragment.bounds.width, fragment.clip.x + fragment.clip.width);
    const bottom_clip = @min(fragment.bounds.y + fragment.bounds.height, fragment.clip.y + fragment.clip.height);
    defer canvas.quads.clipFrom(first, .{ .x = left_clip, .y = top_clip, .width = @max(0, right_clip - left_clip), .height = @max(0, bottom_clip - top_clip) });
    if (selection.range()) |range| {
        var left: ?f32 = null;
        var right: f32 = 0;
        const carets = paint.geometry.carets[fragment.caret_start..][0..fragment.caret_count];
        for (carets, 0..) |caret, index| {
            const at = paint.geometry.position(fragment, index);
            if (!at.before(range[0]) and !range[1].before(at)) {
                left = if (left) |previous| @min(previous, caret.x) else caret.x;
                right = @max(right, caret.x);
            }
        }
        if (left) |x| {
            if (right > x) {
                try canvas.fillAt(.{ .x = fragment.bounds.x + x, .y = fragment.bounds.y, .width = right - x, .height = fragment.bounds.height }, canvas.theme.palette.accent);
                canvas.quads.fadeFrom(first, 0.28);
            }
        }
    }
    if (selection.keyboard) {
        const head = selection.head orelse return;
        for (paint.geometry.carets[fragment.caret_start..][0..fragment.caret_count], 0..) |caret, index| {
            if (head.eql(paint.geometry.position(fragment, index))) {
                try canvas.fillAt(.{ .x = fragment.bounds.x + caret.x, .y = fragment.bounds.y + 2, .width = @max(1, canvas.chrome.px(1.5)), .height = @max(1, fragment.bounds.height - 4) }, canvas.theme.palette.accent);
                return;
            }
        }
    }
}
