const notifications = @import("notifications.zig");
const max_notification_title_bytes = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes = @import("telar-core").max_notification_message_bytes;
const std = @import("std");
const Item = @This();

id: notifications.Id,
level: notifications.Level,
target: notifications.Target,
title_buffer: [max_notification_title_bytes]u8 = undefined,
title_len: u8,
message_buffer: [max_notification_message_bytes]u8 = undefined,
message_len: u8,
phase: notifications.Phase = .entering,
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
    if (full_width == 0 or item.transition_position_ns == 0) {
        return 0;
    }
    if (item.transition_position_ns >= notifications.transition_duration_ns) {
        return full_width;
    }

    const position: u128 = item.transition_position_ns;
    const duration: u128 = notifications.transition_duration_ns;
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

pub fn beginExit(item: *Item, now_ns: u64) bool {
    if (item.phase == .exiting) {
        return false;
    }
    if (item.phase == .entering) {
        _ = item.advanceEntering(now_ns);
    }
    item.phase = .exiting;
    item.transition_updated_ns = now_ns;
    return true;
}

pub fn advanceEntering(item: *Item, now_ns: u64) bool {
    if (now_ns <= item.transition_updated_ns) {
        return false;
    }
    const previous = item.transition_position_ns;
    item.transition_position_ns = @min(
        notifications.transition_duration_ns,
        previous +| (now_ns - item.transition_updated_ns),
    );
    item.transition_updated_ns = now_ns;
    if (item.transition_position_ns == notifications.transition_duration_ns) {
        item.phase = .visible;
    }
    return item.transition_position_ns != previous;
}

pub fn advanceExiting(item: *Item, now_ns: u64) bool {
    if (now_ns <= item.transition_updated_ns) {
        return false;
    }
    const previous = item.transition_position_ns;
    item.transition_position_ns -|= now_ns - item.transition_updated_ns;
    item.transition_updated_ns = now_ns;
    return item.transition_position_ns != previous;
}

pub fn nextDeadline(item: *const Item, now_ns: u64, frame_interval_ns: u64) u64 {
    return switch (item.phase) {
        .entering => @min(
            now_ns +| frame_interval_ns,
            item.transition_updated_ns +| (notifications.transition_duration_ns - item.transition_position_ns),
        ),
        .visible => item.expires_at_ns,
        .exiting => @min(
            now_ns +| frame_interval_ns,
            item.transition_updated_ns +| item.transition_position_ns,
        ),
    };
}
