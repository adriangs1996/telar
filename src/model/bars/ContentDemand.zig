//! What a list of components asks of each bound of `ContentBounds`: how
//! many components, text bytes, click actions and sparkline samples.
const ContentBounds = @import("ContentBounds.zig");
const NodeInput = @import("NodeInput.zig");
const std = @import("std");
const ContentDemand = @This();

nodes: u32 = 0,
text: u32 = 0,
actions: u32 = 0,
samples: u32 = 0,

/// Counts one component and what it stores.
/// Example: `demand.add(input);`
pub fn add(self: *ContentDemand, input: NodeInput) void {
    self.nodes +|= 1;
    self.text +|= saturated(input.text.len + input.detail.len + input.url.len);
    self.samples +|= saturated(input.samples.len);
    if (input.action != null) {
        self.actions +|= 1;
    }
}

/// Whether a list with these bounds holds everything counted.
/// Example: `if (!demand.fits(data.Content.capacity)) ...`
pub fn fits(self: ContentDemand, bounds: ContentBounds) bool {
    return self.nodes <= bounds.nodes and self.text <= bounds.text and self.actions <= bounds.actions and self.samples <= bounds.samples;
}

fn saturated(value: usize) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}
