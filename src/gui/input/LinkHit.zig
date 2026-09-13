//! Owned identity and visible bounds of a link under the native pointer.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Hit = @This();

pane_id: core.PaneId,
generation: u64,
location: core.TabLocation,
content: core.Rect,
scroll_offset: u32 = 0,
area: core.Rect,
match: client.LinkMatch,

/// A gesture can open only the same target in the same attached pane and cells.
/// Example: `if (pressed.eql(&released)) open(pressed.match.target);`
pub fn eql(hit: *const Hit, other: *const Hit) bool {
    return hit.pane_id == other.pane_id and hit.generation == other.generation and
        std.meta.eql(hit.location, other.location) and std.meta.eql(hit.content, other.content) and
        hit.scroll_offset == other.scroll_offset and hit.match.link_index == other.match.link_index and
        std.meta.eql(hit.area, other.area) and std.meta.eql(hit.match.start, other.match.start) and
        std.meta.eql(hit.match.end, other.match.end) and hit.match.target.eql(&other.match.target);
}
