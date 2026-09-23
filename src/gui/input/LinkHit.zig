//! Owned identity and visible bounds of a link under the native pointer.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Hit = @This();

pane_id: core.PaneId,
generation: u64,
location: core.TabLocation,
content: core.Rect,
scroll_offset: u32 = 0,
area: core.Rect,
match: data.LinkMatch,

/// A gesture can open only the same target in the same attached pane and cells.
/// Example: `if (pressed.eql(&released)) open(pressed.match.target);`
pub fn eql(self: *const Hit, other: *const Hit) bool {
    return self.pane_id == other.pane_id and self.generation == other.generation and
        std.meta.eql(self.location, other.location) and std.meta.eql(self.content, other.content) and
        self.scroll_offset == other.scroll_offset and self.match.link_index == other.match.link_index and
        std.meta.eql(self.area, other.area) and std.meta.eql(self.match.start, other.match.start) and
        std.meta.eql(self.match.end, other.match.end) and self.match.target.eql(&other.match.target);
}

/// Uses the same clipped overlay bounds for painting and delivered hit testing.
/// Example: `const area = hit.previewArea();`
pub fn previewArea(self: *const Hit) ?core.Rect {
    if (self.content.h < 2) {
        return null;
    }

    var area = self.content.row(self.content.h -| 1);
    area.w = @min(area.w, 100);
    if (area.y == self.area.y) {
        area.y -= 1;
    }

    return area;
}
