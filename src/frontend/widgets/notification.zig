//! Bounded, client-owned notification state.
//!
//! Notifications are disposable UI state. Wire events are copied into this
//! center, which never allocates after the client starts. When the four slots
//! fill, a new notice replaces the oldest one.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_items = 4;
pub const max_title_bytes = schema.max_notification_title_bytes;
pub const max_message_bytes = schema.max_notification_message_bytes;
/// The transition's wall-clock duration. Frame cadence belongs to the client
/// pacer; changing its FPS changes how often this curve is sampled, not how
/// long the transition lasts.
pub const transition_duration_ns: u64 = 200 * std.time.ns_per_ms;
pub const default_duration_ns: u64 = schema.default_notification_duration_ms *
    std.time.ns_per_ms;

pub const Id = enum(u64) {
    invalid = 0,
    _,
};

pub const Level = enum {
    info,
    success,
    warning,
    failure,
};

/// A click target is a semantic client action, never a callback or pointer.
/// The input router resolves it against current state and safely ignores stale
/// pane, tab, or workspace ids.
pub const Target = union(enum) {
    none,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    select_workspace: schema.WorkspaceId,
};

pub const Input = struct {
    level: Level = .info,
    title: []const u8,
    message: []const u8,
    target: Target = .none,
    duration_ns: u64 = default_duration_ns,
};

const Phase = enum {
    entering,
    visible,
    exiting,
};

pub const Item = struct {
    id: Id,
    level: Level,
    target: Target,
    title_buffer: [max_title_bytes]u8 = undefined,
    title_len: u8,
    message_buffer: [max_message_bytes]u8 = undefined,
    message_len: u8,
    phase: Phase = .entering,
    /// Linear position within the transition. Rendering maps it through a
    /// continuous smoothstep curve, keeping time and presentation separate.
    transition_position_ns: u64 = 0,
    transition_updated_ns: u64,
    expires_at_ns: u64,

    pub fn title(item: *const Item) []const u8 {
        return item.title_buffer[0..item.title_len];
    }

    pub fn message(item: *const Item) []const u8 {
        return item.message_buffer[0..item.message_len];
    }

    /// Applies f(t) = 3t² - 2t³ and rounds to the nearest terminal cell.
    /// u128 intermediates keep the integer-only render path exact and bounded.
    pub fn animatedWidth(item: *const Item, full_width: u16) u16 {
        return @intCast(item.animatedPixels(full_width));
    }

    /// Evaluates the same continuous curve at pixel precision for graphical
    /// placements. FPS only controls how often this value is sampled.
    pub fn animatedPixels(item: *const Item, full_width: u32) u32 {
        if (full_width == 0 or item.transition_position_ns == 0) return 0;
        if (item.transition_position_ns >= transition_duration_ns) return full_width;

        const position: u128 = item.transition_position_ns;
        const duration: u128 = transition_duration_ns;
        const numerator = position * position * (3 * duration - 2 * position);
        const denominator = duration * duration * duration;
        const scaled = @as(u128, full_width) * numerator;
        return @intCast(@min(
            @as(u128, full_width),
            (scaled + denominator / 2) / denominator,
        ));
    }

    pub fn clickable(item: *const Item) bool {
        return std.meta.activeTag(item.target) != .none;
    }

    fn beginExit(item: *Item, now_ns: u64) bool {
        if (item.phase == .exiting) return false;
        if (item.phase == .entering) _ = item.advanceEntering(now_ns);
        item.phase = .exiting;
        item.transition_updated_ns = now_ns;
        return true;
    }

    fn advanceEntering(item: *Item, now_ns: u64) bool {
        if (now_ns <= item.transition_updated_ns) return false;
        const previous = item.transition_position_ns;
        item.transition_position_ns = @min(
            transition_duration_ns,
            previous +| (now_ns - item.transition_updated_ns),
        );
        item.transition_updated_ns = now_ns;
        if (item.transition_position_ns == transition_duration_ns)
            item.phase = .visible;
        return item.transition_position_ns != previous;
    }

    fn advanceExiting(item: *Item, now_ns: u64) bool {
        if (now_ns <= item.transition_updated_ns) return false;
        const previous = item.transition_position_ns;
        item.transition_position_ns -|= now_ns - item.transition_updated_ns;
        item.transition_updated_ns = now_ns;
        return item.transition_position_ns != previous;
    }

    fn nextDeadline(item: *const Item, now_ns: u64, frame_interval_ns: u64) u64 {
        return switch (item.phase) {
            .entering => @min(
                now_ns +| frame_interval_ns,
                item.transition_updated_ns +| (transition_duration_ns - item.transition_position_ns),
            ),
            .visible => item.expires_at_ns,
            .exiting => @min(
                now_ns +| frame_interval_ns,
                item.transition_updated_ns +| item.transition_position_ns,
            ),
        };
    }
};

pub const Center = struct {
    items: [max_items]?Item = @splat(null),
    count: u8 = 0,
    next_id: u64 = 1,

    pub fn push(center: *Center, now_ns: u64, input: Input) Id {
        var item: Item = .{
            .id = .invalid,
            .level = input.level,
            .target = input.target,
            .title_len = 0,
            .message_len = 0,
            .transition_updated_ns = now_ns,
            .expires_at_ns = now_ns +| transition_duration_ns +| input.duration_ns,
        };
        item.title_len = @intCast(copyValidUtf8(&item.title_buffer, input.title));
        item.message_len = @intCast(copyValidUtf8(&item.message_buffer, input.message));

        for (center.items[0..center.count]) |*slot| {
            const existing = if (slot.*) |*value| value else continue;
            if (existing.phase == .exiting or !sameNotification(existing, &item)) continue;
            existing.expires_at_ns = switch (existing.phase) {
                .entering => now_ns +| transition_duration_ns +| input.duration_ns,
                .visible => now_ns +| input.duration_ns,
                .exiting => unreachable,
            };
            return existing.id;
        }

        const id = center.takeId();
        item.id = id;
        if (center.count == max_items) center.count -= 1;
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
        if (index >= center.count) return null;
        return &center.items[index].?;
    }

    /// Returns the next useful wakeup. Moving notifications follow the client
    /// frame cadence; stable notifications sleep until their exact expiry.
    pub fn nextDeadline(
        center: *const Center,
        now_ns: u64,
        frame_interval_ns: u64,
    ) ?u64 {
        std.debug.assert(frame_interval_ns != 0);
        if (center.count == 0) return null;
        var deadline: u64 = std.math.maxInt(u64);
        for (center.items[0..center.count]) |slot| {
            const item = slot orelse continue;
            deadline = @min(deadline, item.nextDeadline(now_ns, frame_interval_ns));
        }
        return deadline;
    }

    /// Advances every transition to its position at `now_ns`. Late frames do
    /// not stretch the animation because position derives from elapsed time.
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
                        if (item.phase == .visible and now_ns >= item.expires_at_ns)
                            continue :item_transition;
                        break :item_transition;
                    },
                    .visible => {
                        if (now_ns < item.expires_at_ns) break :item_transition;
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

    pub fn dismiss(center: *Center, id: Id, now_ns: u64) bool {
        const item = center.find(id) orelse return false;
        return item.beginExit(now_ns);
    }

    pub fn activate(center: *Center, id: Id, now_ns: u64) ?Target {
        const item = center.find(id) orelse return null;
        const target = item.target;
        _ = item.beginExit(now_ns);
        return target;
    }

    fn find(center: *Center, id: Id) ?*Item {
        for (center.items[0..center.count]) |*slot| {
            const item = if (slot.*) |*value| value else continue;
            if (item.id == id) return item;
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

    fn takeId(center: *Center) Id {
        if (center.next_id == 0) center.next_id = 1;
        const id: Id = @enumFromInt(center.next_id);
        center.next_id +%= 1;
        return id;
    }
};

fn sameNotification(left: *const Item, right: *const Item) bool {
    return left.level == right.level and
        std.meta.eql(left.target, right.target) and
        std.mem.eql(u8, left.title(), right.title()) and
        std.mem.eql(u8, left.message(), right.message());
}

fn copyValidUtf8(destination: []u8, source: []const u8) usize {
    const valid = if (std.unicode.utf8ValidateSlice(source)) source else "invalid notification text";
    var len = @min(destination.len, valid.len);
    while (len > 0 and len < valid.len and valid[len] & 0xc0 == 0x80) len -= 1;
    @memcpy(destination[0..len], valid[0..len]);
    return len;
}

test "new notifications replace the oldest at the fixed bound" {
    var center: Center = .{};
    var ids: [max_items + 1]Id = undefined;
    for (&ids, 0..) |*id, index| {
        var title: [8]u8 = undefined;
        id.* = center.push(0, .{
            .title = std.fmt.bufPrint(&title, "n{d}", .{index}) catch unreachable,
            .message = "message",
        });
    }

    try std.testing.expectEqual(@as(u8, max_items), center.count);
    try std.testing.expectEqual(ids[max_items], center.itemAt(0).?.id);
    try std.testing.expect(center.find(ids[0]) == null);
}

test "an active duplicate notification is refreshed instead of stacked" {
    var center: Center = .{};
    const input: Input = .{
        .level = .success,
        .title = "Agent ready",
        .message = "Claude in pane 1 is ready",
        .target = .{ .focus_pane = @enumFromInt(1) },
        .duration_ns = std.time.ns_per_s,
    };
    const first = center.push(0, input);
    _ = center.advance(transition_duration_ns);
    const second = center.push(2 * transition_duration_ns, input);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u8, 1), center.count);
    try std.testing.expectEqual(
        2 * transition_duration_ns + std.time.ns_per_s,
        center.itemAt(0).?.expires_at_ns,
    );
}

test "a duplicate may be shown again after dismissal begins" {
    var center: Center = .{};
    const input: Input = .{ .title = "Ready", .message = "Open result" };
    const first = center.push(0, input);
    try std.testing.expect(center.dismiss(first, 1));
    const second = center.push(2, input);

    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(u8, 2), center.count);
}

test "activation returns a semantic target and starts exit animation" {
    var center: Center = .{};
    const tab_id: schema.TabId = @enumFromInt(7);
    const id = center.push(0, .{
        .title = "Ready",
        .message = "Open the completed tab",
        .target = .{ .select_tab = tab_id },
    });

    const frame_interval_ns = std.time.ns_per_s / 60;
    const now = transition_duration_ns;
    _ = center.advance(now);

    const target = center.activate(id, now).?;
    try std.testing.expectEqual(tab_id, target.select_tab);
    try std.testing.expect(!center.advance(now));
    try std.testing.expect(center.advance(now + frame_interval_ns * 2));
    try std.testing.expect(
        center.itemAt(0).?.animatedWidth(48) < 48,
    );
}

test "notifications follow frame cadence while moving and sleep while stable" {
    var center: Center = .{};
    _ = center.push(0, .{
        .title = "Saved",
        .message = "Configuration reloaded",
        .duration_ns = std.time.ns_per_s,
    });

    const sixty_hz = std.time.ns_per_s / 60;
    const one_twenty_hz = std.time.ns_per_s / 120;
    try std.testing.expectEqual(sixty_hz, center.nextDeadline(0, sixty_hz).?);
    try std.testing.expectEqual(one_twenty_hz, center.nextDeadline(0, one_twenty_hz).?);

    try std.testing.expect(center.advance(transition_duration_ns));
    const expiry = transition_duration_ns + std.time.ns_per_s;
    try std.testing.expectEqual(expiry, center.nextDeadline(transition_duration_ns, sixty_hz).?);

    try std.testing.expect(center.advance(expiry));
    try std.testing.expectEqual(expiry + one_twenty_hz, center.nextDeadline(expiry, one_twenty_hz).?);
    try std.testing.expect(center.advance(expiry + transition_duration_ns));
    try std.testing.expect(!center.hasItems());
    try std.testing.expect(center.nextDeadline(expiry + transition_duration_ns, sixty_hz) == null);
}

test "smoothstep is continuous in time and independent of frame rate" {
    var sixty_hz_center: Center = .{};
    var one_twenty_hz_center: Center = .{};
    _ = sixty_hz_center.push(0, .{ .title = "60 Hz", .message = "same curve" });
    _ = one_twenty_hz_center.push(0, .{ .title = "120 Hz", .message = "same curve" });

    const halfway = transition_duration_ns / 2;
    _ = sixty_hz_center.advance(halfway);
    _ = one_twenty_hz_center.advance(halfway);
    try std.testing.expectEqual(
        sixty_hz_center.itemAt(0).?.animatedWidth(48),
        one_twenty_hz_center.itemAt(0).?.animatedWidth(48),
    );
    try std.testing.expectEqual(@as(u16, 24), sixty_hz_center.itemAt(0).?.animatedWidth(48));
}

test "a late frame catches up without flashing an expired notification" {
    var center: Center = .{};
    _ = center.push(0, .{
        .title = "Old",
        .message = "Do not flash stale state",
        .duration_ns = std.time.ns_per_s,
    });

    const after_exit = std.time.ns_per_s + transition_duration_ns * 2;
    try std.testing.expect(center.advance(after_exit));
    try std.testing.expect(!center.hasItems());
}

test "stored text remains valid utf8 when it hits the byte bound" {
    var center: Center = .{};
    const repeated = "á" ** max_message_bytes;
    _ = center.push(0, .{ .title = "UTF-8", .message = repeated });

    const message = center.itemAt(0).?.message();
    try std.testing.expect(message.len <= max_message_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message));
}
