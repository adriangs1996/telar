//! The pixel controls belonging to one sealed notification frame.
const Target = @import("../interaction/Target.zig");
const Hits = @This();

pub const max_visible = 2;
hits: [max_visible * 2]Target = undefined,
count: usize = 0,

/// Painter order gives the close button precedence over its card.
/// Example: `const target = hits.at(.{ event.x, event.y });`
pub fn at(hits: *const Hits, point: [2]f64) ?Target {
    var index = hits.count;
    while (index > 0) {
        index -= 1;
        if (hits.hits[index].contains(point)) {
            return hits.hits[index];
        }
    }

    return null;
}
