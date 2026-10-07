const core = @import("telar-core");
const notifications = @import("notifications.zig");
const std = @import("std");
const Item = @This();

id: notifications.Id,
level: notifications.Level,
target: notifications.Target,
// SAFETY: Center.push copies valid UTF-8 into the title before publishing the item; title reads only title_len bytes.
title_buffer: [core.max_notification_title_bytes]u8 = undefined,
title_len: u16,
// SAFETY: Center.push copies valid UTF-8 into the message before publishing the item; message reads only message_len bytes.
message_buffer: [core.max_notification_message_bytes]u8 = undefined,
message_len: u16,
// SAFETY: Center.push copies a fitting link before setting link_len; an oversized link retains length zero.
link_buffer: [core.max_notification_link_bytes]u8 = undefined,
link_len: u16 = 0,
phase: NotificationPhase = .entering,
/// Linear position within the transition. Rendering maps it through a
/// continuous smoothstep curve, keeping time and presentation separate.
transition_position_ns: u64 = 0,
transition_updated_ns: u64,
expires_at_ns: u64,

pub fn title(self: *const Item) []const u8 {
    return self.title_buffer[0..self.title_len];
}

pub fn message(self: *const Item) []const u8 {
    return self.message_buffer[0..self.message_len];
}

pub fn link(self: *const Item) []const u8 {
    return self.link_buffer[0..self.link_len];
}

/// The host a click opens, shown on the card before anyone clicks; empty
/// without a link.
pub fn linkHost(self: *const Item) []const u8 {
    return core.notification_link.host(self.link());
}

pub fn clickable(self: *const Item) bool {
    return std.meta.activeTag(self.target) != .none or self.link_len != 0;
}

pub fn beginExit(self: *Item, now_ns: u64) bool {
    if (self.phase == .exiting) {
        return false;
    }
    if (self.phase == .entering) {
        _ = self.advanceEntering(now_ns);
    }
    self.phase = .exiting;
    self.transition_updated_ns = now_ns;
    return true;
}

pub fn advanceEntering(self: *Item, now_ns: u64) bool {
    if (now_ns <= self.transition_updated_ns) {
        return false;
    }
    const previous = self.transition_position_ns;
    self.transition_position_ns = @min(
        notifications.transition_duration_ns,
        previous +| (now_ns - self.transition_updated_ns),
    );
    self.transition_updated_ns = now_ns;
    if (self.transition_position_ns == notifications.transition_duration_ns) {
        self.phase = .visible;
    }
    return self.transition_position_ns != previous;
}

pub fn advanceExiting(self: *Item, now_ns: u64) bool {
    if (now_ns <= self.transition_updated_ns) {
        return false;
    }
    const previous = self.transition_position_ns;
    self.transition_position_ns -|= now_ns - self.transition_updated_ns;
    self.transition_updated_ns = now_ns;
    return self.transition_position_ns != previous;
}

pub fn nextDeadline(self: *const Item, now_ns: u64, frame_interval_ns: u64) u64 {
    return switch (self.phase) {
        .entering => @min(
            now_ns +| frame_interval_ns,
            self.transition_updated_ns +| (notifications.transition_duration_ns - self.transition_position_ns),
        ),
        .visible => self.expires_at_ns,
        .exiting => @min(
            now_ns +| frame_interval_ns,
            self.transition_updated_ns +| self.transition_position_ns,
        ),
    };
}

const NotificationPhase = enum {
    entering,
    visible,
    exiting,
};
