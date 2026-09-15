//! A drag retains the delivered slots at press so moving labels cannot chase
//! the pointer or oscillate between insertion positions beneath it.
const core = @import("telar-core");
const Slot = @import("../TabSlot.zig");
const Registry = @import("Registry.zig");
const Pointer = @import("../../input/PointerEvent.zig");
const TabDropSlots = @This();

entries: [core.max_tabs_per_workspace]Slot = undefined,
len: usize = 0,

/// Example: `slots.capture(dispatcher.maps.presented());`
pub fn capture(slots: *TabDropSlots, registry: *const Registry) void {
    slots.len = 0;
    for (registry.targets[0..registry.len]) |target| {
        if (target.enabled and target.layer == 0 and target.action == .intent and target.action.intent == .select_tab and slots.len < slots.entries.len) {
            slots.entries[slots.len] = .{ .id = target.action.intent.select_tab, .bounds = target.bounds };
            slots.len += 1;
        }
    }
}

/// Example: `const destination = slots.at(pointer);`
pub fn at(slots: *const TabDropSlots, pointer: Pointer) ?core.TabMoveTarget {
    var nearest: ?Slot = null;
    var distance: f64 = @import("std").math.inf(f64);
    var left: f64 = @import("std").math.inf(f64);
    var right: f64 = -@import("std").math.inf(f64);
    for (slots.entries[0..slots.len]) |slot| {
        if (pointer.y < slot.bounds.y or pointer.y >= slot.bounds.y + slot.bounds.height) {
            continue;
        }

        left = @min(left, slot.bounds.x);
        right = @max(right, slot.bounds.x + slot.bounds.width);

        const dx = @max(0, @max(slot.bounds.x - pointer.x, pointer.x - (slot.bounds.x + slot.bounds.width)));
        if (dx < distance) {
            nearest = slot;
            distance = dx;
        }
    }

    if (pointer.x < left or pointer.x >= right) {
        return null;
    }

    const target = nearest orelse return null;
    return .{ .relative_to = target.id, .direction = if (pointer.x < target.bounds.x + target.bounds.width / 2) .previous else .next };
}
