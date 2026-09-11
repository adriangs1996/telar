const RegionType = @import("../workspace/Region.zig");
const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const GeometryPane = @import("GeometryPane.zig");
const ProjectionType = @import("Projection.zig");
const std = @import("std");
const Geometry = @This();

region: RegionType = .{ .area = .{}, .revision = 0 },
location: ?TabLocationType = null,
layout_revision: u64 = 0,
host_size: TerminalSizeType = .{ .cols = 0, .rows = 0 },
panes: [max_panes_per_tab_module]GeometryPane = undefined,
len: u8 = 0,

/// Captures coordinate identity, not cells or model pointers.
/// Example: `const geometry = Geometry.capture(projection);`.
pub fn capture(projection: ProjectionType) Geometry {
    var geometry: Geometry = .{ .region = projection.geometry, .host_size = projection.host_size };
    const model = projection.model orelse return geometry;
    geometry.location = model.location;
    geometry.layout_revision = model.layout.currentRevision();
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
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
pub fn matches(delivered: *const Geometry, current: *const Geometry) bool {
    if (!delivered.region.matches(current.region) or
        !std.meta.eql(delivered.location, current.location) or
        delivered.layout_revision != current.layout_revision or
        !std.meta.eql(delivered.host_size, current.host_size) or delivered.len != current.len)
    {
        return false;
    }

    for (delivered.panes[0..delivered.len], current.panes[0..current.len]) |old, new| {
        if (!std.meta.eql(old, new)) {
            return false;
        }
    }

    return true;
}
