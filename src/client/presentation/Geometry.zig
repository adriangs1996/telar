const data = @import("model");
const core = @import("telar-core");
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
/// Copies `source` without the unused tail of `panes`, kilobytes that a
/// whole-struct copy would move for one pane.
/// Example: `flight.geometry.copyFrom(&submission.geometry);`
pub fn copyFrom(self: *Geometry, source: *const Geometry) void {
    comptime std.debug.assert(std.meta.fields(Geometry).len == 6);

    self.region = source.region;
    self.location = source.location;
    self.layout_revision = source.layout_revision;
    self.host_size = source.host_size;
    self.len = source.len;
    @memcpy(self.panes[0..source.len], source.panes[0..source.len]);
}

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

const GeometryPane = struct {
    id: core.PaneId,
    attachment_generation: u64,
    cols: u16,
    rows: u16,
};
