//! Bounded notification state owned by `ClientModel`.
//!
//! Notifications are disposable UI state. Wire events are copied into this
//! value, which never allocates after the client starts. Renderers borrow an
//! immutable snapshot. When the four slots fill, a new notice replaces the
//! oldest one.

const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");
const core = @import("telar-core");
const std = @import("std");
const Item = @import("NotificationItem.zig");

/// Where a published notice is surfaced besides the in-app center.
pub const Delivery = @import("NotificationDelivery.zig").NotificationDelivery;

pub const max_items = 4;

/// The transition's wall-clock duration. Frame cadence belongs to the client
/// pacer; changing its FPS changes how often this curve is sampled, not how
/// long the transition lasts.
pub const transition_duration_ns: u64 = 200 * std.time.ns_per_ms;
pub const default_duration_ns: u64 = core.default_notification_duration_ms *
    std.time.ns_per_ms;

pub const Id = @import("NotificationId.zig").NotificationId;

pub const Level = @import("NotificationLevel.zig").NotificationLevel;

/// A click target is a semantic client action, never a callback or pointer.
/// The input router resolves it against current state and safely ignores stale
/// pane, tab, or workspace ids.
pub const Target = @import("NotificationTarget.zig").NotificationTarget;

pub fn sameNotification(left: *const Item, right: *const Item) bool {
    return left.level == right.level and
        std.meta.eql(left.target, right.target) and
        std.mem.eql(
            u8,
            left.title(),
            right.title(),
        ) and
        std.mem.eql(
            u8,
            left.message(),
            right.message(),
        ) and
        std.mem.eql(
            u8,
            left.link(),
            right.link(),
        );
}

pub fn copyValidUtf8(destination: []u8, source: []const u8) usize {
    const valid = if (std.unicode.utf8ValidateSlice(source)) source else "invalid notification text";
    var len = @min(destination.len, valid.len);
    while (len > 0 and len < valid.len and valid[len] & 0xc0 == 0x80) len -= 1;
    @memcpy(destination[0..len], valid[0..len]);
    return len;
}

/// Publishes one bounded client notification and advances its isolated
/// version. The center owns all borrowed text before this call returns.
///
/// ```zig
/// const publication = notifications.publish(model, now_ns, input);
/// ```
pub fn publish(model: *ClientModel, now_ns: u64, input: model_data.NotificationInput) model_data.NotificationPublication {
    const id = model.notification_center.push(now_ns, input);
    model.notifications_revision +%= 1;

    return .{
        .id = id,
        .notifications_revision = model.notifications_revision,
    };
}

/// Advances notification lifecycles to one monotonic timestamp.
///
/// ```zig
/// const change = notifications.advance(model, now_ns) orelse return;
/// ```
pub fn advance(model: *ClientModel, now_ns: u64) ?model_data.NotificationChange {
    if (!model.notification_center.advance(now_ns)) {
        return null;
    }

    model.notifications_revision +%= 1;
    return .{ .notifications_revision = model.notifications_revision };
}

/// Starts one notification's exit transition and returns its semantic
/// target. Missing and already exiting identities are stale no-ops.
///
/// ```zig
/// const activation = notifications.activate(model, id, now_ns) orelse return;
/// ```
pub fn activate(model: *ClientModel, id: model_data.NotificationId, now_ns: u64) ?model_data.NotificationActivation {
    const target = model.notification_center.activate(id, now_ns) orelse return null;
    model.notifications_revision +%= 1;

    return .{
        .target = target,
        .notifications_revision = model.notifications_revision,
    };
}

/// Starts one notification's exit transition without activating it.
///
/// ```zig
/// const change = notifications.dismiss(model, id, now_ns) orelse return;
/// ```
pub fn dismiss(model: *ClientModel, id: model_data.NotificationId, now_ns: u64) ?model_data.NotificationChange {
    if (!model.notification_center.dismiss(id, now_ns)) {
        return null;
    }

    model.notifications_revision +%= 1;
    return .{ .notifications_revision = model.notifications_revision };
}
