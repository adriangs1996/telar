//! Typed, bounded effects returned by a runtime tap worker.

const Notification = @import("Notification.zig");

pub const max_effects = 16;
pub const max_effect_bytes = 64 * 1024;

pub const Effect = union(enum) {
    notification: Notification,
};
