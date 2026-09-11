const Geometry = @This();
const workspace = @import("../workspace/root.zig");
const schema = @import("telar-core").schema;
const presentation = @import("root.zig");
const std = @import("std");
region: workspace.geometry.Region = .{ .area = .{}, .revision = 0 },
location: ?schema.TabLocation = null,
layout_revision: u64 = 0,
host_size: schema.TerminalSize = .{ .cols = 0, .rows = 0 },
panes: [schema.max_panes_per_tab]Pane = undefined,
len: u8 = 0,

const Pane = struct {
    id: schema.PaneId,
    attachment_generation: u64,
    cols: u16,
    rows: u16,
};

/// Captures coordinate identity, not cells or model pointers.
/// Example: `const geometry = Geometry.capture(projection);`.
pub fn capture(projection: presentation.Projection) Geometry {
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
