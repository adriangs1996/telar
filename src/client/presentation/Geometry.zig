const data = @import("model");
const core = @import("telar-core");
const GeometryPane = @import("GeometryPane.zig");
const Projection = @import("Projection.zig");
const std = @import("std");
const Geometry = @This();

region: data.Region = .{ .area = .{}, .revision = 0 },
location: ?core.TabLocation = null,
layout_revision: u64 = 0,
host_size: core.TerminalSize = .{ .cols = 0, .rows = 0 },
panes: [core.max_panes_per_tab]GeometryPane = undefined,
len: u8 = 0,

/// Captures coordinate identity, not cells or model pointers.
/// Example: `const geometry = Geometry.capture(projection);`.
pub fn capture(projection: Projection) Geometry {
    var geometry: Geometry = .{ .region = projection.geometry, .host_size = projection.host_size };
    const slot = projection.tab orelse return geometry;
    const model = projection.model;
    const tab_id = model.tabs.location[slot].tab_id;
    geometry.location = if (model.panes.countIn(tab_id) == 0) null else model.tabs.location[slot];
    geometry.layout_revision = model.tabs.layout[slot].currentRevision();
    var panes = model.panes.iterateConst(tab_id);
    while (panes.next()) |pane| {
        geometry.panes[geometry.len] = .{
            .id = pane.id,
            .attachment_generation = pane.attachment_generation,
            .cols = pane.buffer.w,
            .rows = pane.buffer.h,
        };
        geometry.len += 1;
    }

    return geometry;
}

/// Checks a new gesture against delivered geometry. Captured gestures keep
/// their original owner and must not be reassigned on a failed match.
/// Example: `if (!delivered.matches(current)) return;`.
pub fn matches(self: *const Geometry, current: *const Geometry) bool {
    if (!self.region.matches(current.region) or
        !std.meta.eql(self.location, current.location) or
        self.layout_revision != current.layout_revision or
        !std.meta.eql(self.host_size, current.host_size) or self.len != current.len)
    {
        return false;
    }

    for (self.panes[0..self.len], current.panes[0..current.len]) |old, new| {
        if (!std.meta.eql(old, new)) {
            return false;
        }
    }

    return true;
}
