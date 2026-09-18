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
pub fn add(registry: *Registry, target: Target) !void {
    const bounds = target.bounds;
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width < 0 or bounds.height < 0) {
        return error.InvalidWidgetBounds;
    }

    if (bounds.width == 0 or bounds.height == 0) {
        return;
    }

    if (registry.len == capacity) {
        return error.WidgetTargetCapacityExceeded;
    }

    if (registry.find(target.id) != null) {
        return error.DuplicateWidgetIdentity;
    }

    registry.targets[registry.len] = target;
    registry.len += 1;
}

/// Example: `const target = registry.find(id) orelse return;`
pub fn find(registry: *const Registry, id: Id) ?Target {
    for (registry.targets[0..registry.len]) |target| {
        if (target.id.eql(id)) {
            return target;
        }
    }

    return null;
}

/// Later declarations take precedence within the active modal scope.
/// Example: `const target = registry.at(.{ event.x, event.y });`
pub fn at(registry: *const Registry, point: [2]f64) ?Target {
    var index = registry.len;
    while (index > 0) {
        index -= 1;
        const target = registry.targets[index];
        if (target.accepts_pointer and target.layer >= registry.modal_layer and target.contains(point)) {
            return target;
        }
    }

    return null;
}

/// Compares initialized semantic fields only, excluding unused text/storage.
/// Example: `if (!delivered.equivalent(prepared)) publishAccessibility();`
pub fn equivalent(left: *const Registry, right: *const Registry) bool {
    if (left.len != right.len or left.modal_layer != right.modal_layer) {
        return false;
    }

    for (left.targets[0..left.len], right.targets[0..right.len]) |a, b| {
        if (!a.id.eql(b.id) or !std.meta.eql(a.bounds, b.bounds) or !std.meta.eql(a.action, b.action) or a.layer != b.layer or a.focusable != b.focusable or a.enabled != b.enabled or a.accepts_pointer != b.accepts_pointer or a.role != b.role or a.scroll_limit != b.scroll_limit or a.scroll_step != b.scroll_step or a.thread_header_offset != b.thread_header_offset or a.thread_first_key != b.thread_first_key or a.thread_last_key != b.thread_last_key or a.thread_first_offset != b.thread_first_offset or a.thread_last_offset != b.thread_last_offset or a.thread_window_revision != b.thread_window_revision or a.thread_history_generation != b.thread_history_generation or a.thread_anchor_revision != b.thread_anchor_revision or a.thread_scroll_value != b.thread_scroll_value or a.thread_resolved_scroll != b.thread_resolved_scroll or a.thread_reanchor != b.thread_reanchor or a.thread_skip_folded != b.thread_skip_folded or a.traverse_tab != b.traverse_tab or !std.mem.eql(u8, a.label[0..a.label_len], b.label[0..b.label_len])) {
            return false;
        }
    }

    return true;
}
