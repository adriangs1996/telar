//! One bounded presentation's owned hit and focus targets.
const std = @import("std");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const Registry = @This();

pub const capacity = 256;
targets: [capacity]Target = undefined,
len: usize = 0,
modal_layer: u8 = 0,

/// Rejects invalid geometry, duplicate identities and capacity failure before
/// publishing an unreachable control. Empty clipped targets are omitted.
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
        return error.WidgetTargetCapacityExceeded;
    }

    if (self.find(target.id) != null) {
        return error.DuplicateWidgetIdentity;
    }

    self.targets[self.len] = target;
    self.len += 1;
}

/// Example: `const target = registry.find(id) orelse return;`
pub fn find(self: *const Registry, id: Id) ?Target {
    for (self.targets[0..self.len]) |target| {
        if (target.id.eql(id)) {
            return target;
        }
    }

    return null;
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
