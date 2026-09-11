const Center = @This();
const source_namespace = @import("root.zig");
const Item = @import("Item.zig");
const Input = @import("Input.zig");
const std = @import("std");
items: [source_namespace.max_items]?Item = @splat(null),
count: u8 = 0,
next_id: u64 = 1,

/// Copies one notice into bounded storage, refreshing an equivalent active
/// item instead of stacking it.
///
/// ```zig
/// const id = center.push(now_ns, input);
/// ```
pub fn push(center: *Center, now_ns: u64, input: Input) source_namespace.Id {
    var item: Item = .{
        .id = .invalid,
        .level = input.level,
        .target = input.target,
        .title_len = 0,
        .message_len = 0,
        .transition_updated_ns = now_ns,
        .expires_at_ns = now_ns +| source_namespace.transition_duration_ns +| input.duration_ns,
    };
    item.title_len = @intCast(source_namespace.copyValidUtf8(&item.title_buffer, input.title));
    item.message_len = @intCast(source_namespace.copyValidUtf8(&item.message_buffer, input.message));

    for (center.items[0..center.count]) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (existing.phase == .exiting or !source_namespace.sameNotification(existing, &item)) {
            continue;
        }
        existing.expires_at_ns = switch (existing.phase) {
            .entering => now_ns +| source_namespace.transition_duration_ns +| input.duration_ns,
            .visible => now_ns +| input.duration_ns,
            .exiting => unreachable,
        };
        return existing.id;
    }

    const id = center.takeId();
    item.id = id;
    if (center.count == source_namespace.max_items) {
        center.count -= 1;
    }
    var index: usize = center.count;
    while (index > 0) : (index -= 1) center.items[index] = center.items[index - 1];
    center.items[0] = item;
    center.count += 1;
    return id;
}

pub fn hasItems(center: *const Center) bool {
    return center.count != 0;
}

pub fn itemAt(center: *const Center, index: usize) ?*const Item {
    if (index >= center.count) {
        return null;
    }
    return &center.items[index].?;
}

/// Returns the next useful wakeup. Moving notifications follow the client
/// frame cadence; stable notifications sleep until their exact expiry.
///
/// ```zig
/// const deadline = center.nextDeadline(now_ns, frame_interval_ns);
/// ```
pub fn nextDeadline(center: *const Center, now_ns: u64, frame_interval_ns: u64) ?u64 {
    std.debug.assert(frame_interval_ns != 0);
    if (center.count == 0) {
        return null;
    }
    var deadline: u64 = std.math.maxInt(u64);
    for (center.items[0..center.count]) |slot| {
        const item = slot orelse continue;
        deadline = @min(deadline, item.nextDeadline(now_ns, frame_interval_ns));
    }
    return deadline;
}

/// Advances every transition to its position at `now_ns`. Late frames do
/// not stretch the animation because position derives from elapsed time.
///
/// ```zig
/// const changed = center.advance(now_ns);
/// ```
pub fn advance(center: *Center, now_ns: u64) bool {
    var changed = false;
    var index: usize = 0;
    while (index < center.count) {
        const item = &center.items[index].?;
        var remove = false;
        item_transition: while (true) {
            switch (item.phase) {
                .entering => {
                    changed = item.advanceEntering(now_ns) or changed;
                    if (item.phase == .visible and now_ns >= item.expires_at_ns) {
                        continue :item_transition;
                    }
                    break :item_transition;
                },
                .visible => {
                    if (now_ns < item.expires_at_ns) {
                        break :item_transition;
                    }
                    item.phase = .exiting;
                    item.transition_updated_ns = item.expires_at_ns;
                    changed = true;
                },
                .exiting => {
                    changed = item.advanceExiting(now_ns) or changed;
                    remove = item.transition_position_ns == 0;
                    break :item_transition;
                },
            }
        }
        if (remove) {
            center.removeAt(index);
            changed = true;
            continue;
        }
        index += 1;
    }
    return changed;
}

/// Starts an item's exit transition without following its target.
///
/// ```zig
/// const changed = center.dismiss(id, now_ns);
/// ```
pub fn dismiss(center: *Center, id: source_namespace.Id, now_ns: u64) bool {
    const item = center.find(id) orelse return false;
    return item.beginExit(now_ns);
}

/// Starts an item's exit transition and returns its semantic target once.
///
/// ```zig
/// const target = center.activate(id, now_ns) orelse return;
/// ```
pub fn activate(center: *Center, id: source_namespace.Id, now_ns: u64) ?source_namespace.Target {
    const item = center.find(id) orelse return null;
    const target = item.target;
    if (!item.beginExit(now_ns)) {
        return null;
    }

    return target;
}

pub fn find(center: *Center, id: source_namespace.Id) ?*Item {
    for (center.items[0..center.count]) |*slot| {
        const item = if (slot.*) |*value| value else continue;
        if (item.id == id) {
            return item;
        }
    }
    return null;
}

fn removeAt(center: *Center, removed: usize) void {
    std.debug.assert(removed < center.count);
    var index = removed;
    while (index + 1 < center.count) : (index += 1)
        center.items[index] = center.items[index + 1];
    center.count -= 1;
    center.items[center.count] = null;
}

fn takeId(center: *Center) source_namespace.Id {
    if (center.next_id == 0) {
        center.next_id = 1;
    }
    const id: source_namespace.Id = @enumFromInt(center.next_id);
    center.next_id +%= 1;
    return id;
}
