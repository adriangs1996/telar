//! One bounded presentation's owned hit and focus targets.
const std = @import("std");
const core = @import("telar-core");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const BandHitMap = @import("../BandHitMap.zig");
const Registry = @This();

/// Room for every chrome band target (`BandHitMap.capacity`), the open
/// overlay's rows and editors; it
/// follows the band when the bar and panel limits grow it, rounded to a
/// power of two because `probe` wraps its index with a mask.
pub const capacity = std.math.ceilPowerOfTwoAssert(usize, @max(1024, 2 * BandHitMap.capacity));
pub const limit = core.Limit.declare("gui.widgets.registry_capacity", "widget targets", capacity);

comptime {
    // Every chrome band target fits with room for an open overlay's rows.
    std.debug.assert(capacity >= 2 * BandHitMap.capacity);
    std.debug.assert(std.math.isPowerOfTwo(index_len));
    // A row index never reaches the empty marker.
    std.debug.assert(capacity < empty_row);
}
/// Open-addressed index from identity to row, twice the rows so probes
/// stay short; a duplicate identity is found in one probe run.
const index_len = 2 * capacity;
const empty_row = std.math.maxInt(u16);

// SAFETY: add writes a target before returning with its index and length published; reset clears the index and len before reuse.
targets: [capacity]Target = undefined,
len: usize = 0,
modal_layer: u8 = 0,
index: [index_len]u16 = @splat(empty_row),
/// Targets left out because the registry was full; their controls still
/// draw and the window reports `gui.widgets.registry_capacity`.
dropped: usize = 0,

/// Rejects invalid geometry and duplicate identities. A full registry keeps
/// the targets it holds and counts the rest as dropped, so the frame still
/// draws. Empty clipped targets are omitted.
/// Example: `try registry.add(.{ .id = id, .bounds = bounds, .action = .{ .custom = 1 } });`
pub fn add(self: *Registry, target: Target) !void {
    const bounds = target.bounds;
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width < 0 or bounds.height < 0) {
        return error.InvalidWidgetBounds;
    }

    if (bounds.width == 0 or bounds.height == 0) {
        return;
    }

    if (self.len == capacity) {
        self.dropped += 1;
        return;
    }

    const position = self.probe(target.id);
    if (self.index[position] != empty_row) {
        return error.DuplicateWidgetIdentity;
    }

    self.index[position] = @intCast(self.len);
    self.targets[self.len] = target;
    self.len += 1;
}

/// Empties the registry for the next frame without touching its rows.
/// Example: `registry.reset();`
pub fn reset(self: *Registry) void {
    self.len = 0;
    self.dropped = 0;
    self.modal_layer = 0;
    @memset(&self.index, empty_row);
}

/// Example: `const target = registry.find(id) orelse return;`
pub fn find(self: *const Registry, id: Id) ?Target {
    const row = self.index[self.probe(id)];
    return if (row == empty_row) null else self.targets[row];
}

/// The index position holding `id`, or the empty one where it would go.
fn probe(self: *const Registry, id: Id) usize {
    var position: usize = @intCast((std.hash.int(id.target_id) ^ std.hash.int(id.generation)) & (index_len - 1));
    while (self.index[position] != empty_row and !self.targets[self.index[position]].id.eql(id)) {
        position = (position + 1) & (index_len - 1);
    }

    return position;
}

/// Later declarations take precedence within the active modal scope.
/// Example: `const target = registry.at(.{ event.x, event.y });`
pub fn at(self: *const Registry, point: [2]f64) ?Target {
    var index = self.len;
    while (index > 0) {
        index -= 1;
        const target = self.targets[index];
        if (target.accepts_pointer and target.layer >= self.modal_layer and target.contains(point)) {
            return target;
        }
    }

    return null;
}

/// Compares initialized semantic fields only, excluding unused text/storage.
/// Example: `if (!delivered.equivalent(prepared)) publishAccessibility();`
pub fn equivalent(self: *const Registry, right: *const Registry) bool {
    if (self.len != right.len or self.modal_layer != right.modal_layer) {
        return false;
    }

    for (self.targets[0..self.len], right.targets[0..right.len]) |a, b| {
        if (!a.id.eql(b.id) or !std.meta.eql(a.bounds, b.bounds) or !std.meta.eql(a.action, b.action) or a.layer != b.layer or a.focusable != b.focusable or a.enabled != b.enabled or a.accepts_pointer != b.accepts_pointer or a.role != b.role or a.scroll_limit != b.scroll_limit or a.scroll_step != b.scroll_step or !std.mem.eql(u8, a.label[0..a.label_len], b.label[0..b.label_len])) {
            return false;
        }
    }

    return true;
}
