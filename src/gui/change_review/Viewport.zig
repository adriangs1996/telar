//! Delivered row positions keep page motions proportional to the visible diff,
//! including wrapped code and inline comments.
const client = @import("telar-client");
const std = @import("std");
const Viewport = @This();
const row_capacity = @typeInfo(@FieldType(client.ChangeReviewRevision, "rows")).array.len;

height: f32 = 0,
line_height: f32 = 1,
maximum_scroll: f32 = 0,
starts: [row_capacity]f32 = @splat(0),
ends: [row_capacity]f32 = @splat(0),
generation: u64 = 0,
file: usize = 0,

/// Moves through selectable rows toward a visible pixel position. Returns false
/// at a file or visual boundary; wrapped fragments can keep the same logical row.
/// Example: `_ = viewport.move(&model, .{ .fraction = 0.5, .scroll = scroll });`
pub fn move(self: *const Viewport, model: *client.ChangeReviewModel, request: struct { fraction: f32, scroll: f32 }) bool {
    const start = std.math.clamp(self.starts[model.head], request.scroll, request.scroll + @max(0, self.height - self.line_height));
    const destination = start + self.height * request.fraction;
    model.search.match = null;
    while (true) {
        if (destination >= self.starts[model.head] and destination < self.ends[model.head]) {
            return true;
        }

        const previous = model.head;
        model.move(.{ .delta = if (request.fraction < 0) -1 else 1, .extend = model.visual });
        if (model.head == previous) {
            return false;
        }
        if ((request.fraction > 0 and self.starts[model.head] >= destination) or (request.fraction < 0 and self.ends[model.head] <= destination)) {
            return true;
        }
    }
}
