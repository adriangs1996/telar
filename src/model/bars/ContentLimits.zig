//! The named limits of one kind of component list, one per bound, which a
//! render that returns more than the list holds reports.
const core = @import("telar-core");
const ContentBounds = @import("ContentBounds.zig");
const ContentLimits = @This();

nodes: core.Limit,
text: core.Limit,
actions: core.Limit,
samples: core.Limit,

/// The capacities of a list that reports these limits.
/// Example: `const Content = GenericContent(bar_limits.bounds());`
pub fn bounds(self: ContentLimits) ContentBounds {
    return .{
        .nodes = @intCast(self.nodes.value),
        .text = @intCast(self.text.value),
        .actions = @intCast(self.actions.value),
        .samples = @intCast(self.samples.value),
    };
}
