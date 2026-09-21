const std = @import("std");
const core = @import("telar-core");
const ChangeReviewAvailability = @This();

pane_generation: u64 = 0,
attachment_generation: u64 = 0,
latest_edition_id: u64 = 0,
session_bytes: [core.change_review.max_identity_bytes]u8 = undefined,
session_len: usize = 0,

/// Owns the runtime summary independently of an open review or receive buffer.
/// Example: `_ = availability.apply(notification, attachment_generation);`
pub fn apply(self: *ChangeReviewAvailability, notification: core.ChangeReviewChanged, attachment_generation: u64) bool {
    if (notification.session.len > self.session_bytes.len) {
        return false;
    }

    const same = self.pane_generation == notification.pane_generation and self.attachment_generation == attachment_generation and std.mem.eql(u8, self.session_bytes[0..self.session_len], notification.session);
    if (same and (notification.latest_edition_id == self.latest_edition_id or (notification.latest_edition_id != 0 and notification.latest_edition_id < self.latest_edition_id))) {
        return false;
    }

    self.pane_generation = notification.pane_generation;
    self.attachment_generation = attachment_generation;
    self.latest_edition_id = notification.latest_edition_id;
    @memcpy(self.session_bytes[0..notification.session.len], notification.session);
    self.session_len = notification.session.len;
    return true;
}

/// Retires availability when a managed pane switches provider conversations.
/// Example: `availability.retainSession(thread.threadId());`
pub fn retainSession(self: *ChangeReviewAvailability, session: []const u8) void {
    if (!std.mem.eql(u8, self.session_bytes[0..self.session_len], session)) {
        self.* = .{};
    }
}
