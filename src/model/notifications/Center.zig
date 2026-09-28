const notifications = @import("notifications.zig");
const Item = @import("NotificationItem.zig");
const Input = @import("NotificationInput.zig");
const std = @import("std");
const Center = @This();

items: [notifications.max_items]?Item = @splat(null),
count: u8 = 0,
next_id: u64 = 1,

/// Copies one notice into bounded storage, refreshing an equivalent active
/// item instead of stacking it.
///
/// ```zig
/// const id = center.push(now_ns, input);
/// ```
pub fn push(self: *Center, now_ns: u64, input: Input) notifications.Id {
    var item: Item = .{
        .id = .invalid,
        .level = input.level,
        .target = input.target,
        .title_len = 0,
        .message_len = 0,
        .transition_updated_ns = now_ns,
        .expires_at_ns = now_ns +| notifications.transition_duration_ns +| input.duration_ns,
    };
    item.title_len = @intCast(notifications.copyValidUtf8(&item.title_buffer, input.title));
    item.message_len = @intCast(notifications.copyValidUtf8(&item.message_buffer, input.message));
    // A link longer than the buffer is dropped whole, never cut into another URL.
    if (input.link.len <= item.link_buffer.len) {
        @memcpy(item.link_buffer[0..input.link.len], input.link);
        item.link_len = @intCast(input.link.len);
    }

    for (self.items[0..self.count]) |*slot| {
        const existing = if (slot.*) |*value| value else continue;
        if (existing.phase == .exiting or !notifications.sameNotification(existing, &item)) {
            continue;
        }
        existing.expires_at_ns = switch (existing.phase) {
            .entering => now_ns +| notifications.transition_duration_ns +| input.duration_ns,
            .visible => now_ns +| input.duration_ns,
            .exiting => unreachable,
        };
        return existing.id;
    }

    const id = self.takeId();
    item.id = id;
    if (self.count == notifications.max_items) {
        self.count -= 1;
    }
    var index: usize = self.count;
    while (index > 0) : (index -= 1) self.items[index] = self.items[index - 1];
    self.items[0] = item;
    self.count += 1;
    return id;
}

pub fn hasItems(self: *const Center) bool {
    return self.count != 0;
}

pub fn itemAt(self: *const Center, index: usize) ?*const Item {
    if (index >= self.count) {
        return null;
    }
    return &self.items[index].?;
}

/// Returns the next useful wakeup. Moving notifications follow the client
/// frame cadence; stable notifications sleep until their exact expiry.
///
/// ```zig
/// const deadline = center.nextDeadline(now_ns, frame_interval_ns);
/// ```
pub fn nextDeadline(self: *const Center, now_ns: u64, frame_interval_ns: u64) ?u64 {
    std.debug.assert(frame_interval_ns != 0);
    if (self.count == 0) {
        return null;
    }
    var deadline: u64 = std.math.maxInt(u64);
    for (self.items[0..self.count]) |slot| {
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
pub fn advance(self: *Center, now_ns: u64) bool {
    var changed = false;
    var index: usize = 0;
    while (index < self.count) {
        const item = &self.items[index].?;
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
            self.removeAt(index);
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
pub fn dismiss(self: *Center, id: notifications.Id, now_ns: u64) bool {
    const item = self.find(id) orelse return false;
    return item.beginExit(now_ns);
}

/// Starts an item's exit transition and returns its semantic target once.
///
/// ```zig
/// const target = center.activate(id, now_ns) orelse return;
/// ```
pub fn activate(self: *Center, id: notifications.Id, now_ns: u64) ?notifications.Target {
    const item = self.find(id) orelse return null;
    const target = item.target;
    if (!item.beginExit(now_ns)) {
        return null;
    }

    return target;
}

pub fn find(self: *Center, id: notifications.Id) ?*Item {
    for (self.items[0..self.count]) |*slot| {
        const item = if (slot.*) |*value| value else continue;
        if (item.id == id) {
            return item;
        }
    }
    return null;
}

fn removeAt(self: *Center, removed: usize) void {
    std.debug.assert(removed < self.count);
    var index = removed;
    while (index + 1 < self.count) : (index += 1)
        self.items[index] = self.items[index + 1];
    self.count -= 1;
    self.items[self.count] = null;
}

fn takeId(self: *Center) notifications.Id {
    if (self.next_id == 0) {
        self.next_id = 1;
    }
    const id: notifications.Id = @enumFromInt(self.next_id);
    self.next_id +%= 1;
    return id;
}
