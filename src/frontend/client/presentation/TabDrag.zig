//! Cell targets become authoritative only after their frame is delivered.
const client = @import("telar-client");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const widget = @import("../../widgets/context_support.zig");
const GenericHits = @import("../../ui/GenericHits.zig").Type;
const TabDrag = @This();

gesture: client.TabDrag = .{},
escape_key: ?data.Physical = null,
hits: GenericHits(core.TabId, core.max_tabs_per_workspace) = .{},
workspace: ?core.WorkspaceLocation = null,

/// Example: `drag.present(&view.hits, delivered_workspace);`
pub fn present(self: *TabDrag, hits: *const widget.Hits, workspace: ?core.WorkspaceLocation) void {
    if (self.gesture.source) |source| {
        if (!std.meta.eql(@as(?core.WorkspaceLocation, source.workspace), workspace)) {
            self.gesture.cancel();
        }
    }

    self.hits.clear();
    self.workspace = workspace;
    for (hits.registered()) |hit| {
        if (hit.action == .select_tab) {
            const visible = hits.at(hit.rect.x, hit.rect.y);
            if (visible != null and visible.? == .select_tab and visible.?.select_tab == hit.action.select_tab) {
                self.hits.add(hit.rect, hit.action.select_tab);
            }
        }
    }
}

/// Includes the one-cell gaps between tabs in the nearest insertion slot.
/// Example: `const target = drag.destination(mouse);`
pub fn destination(self: *const TabDrag, mouse: data.Mouse) ?core.TabMoveTarget {
    const entries = self.hits.registered();
    if (entries.len == 0) {
        return null;
    }

    const first = entries[0].rect;
    const last = entries[entries.len - 1].rect;
    if (mouse.y != first.y or mouse.x < first.x or mouse.x >= last.x + last.w) {
        return null;
    }

    for (entries) |entry| {
        if (mouse.x < entry.rect.x + entry.rect.w) {
            return .{ .relative_to = entry.action, .direction = if (@as(u32, mouse.x) * 2 < @as(u32, entry.rect.x) * 2 + entry.rect.w) .previous else .next };
        }
    }

    return null;
}
