//! Application policy for delivering one classified clipboard image result.

const std = @import("std");
const notification_capability = @import("../../../notifications/root.zig");
const clipboard_image = @import("clipboard_image.zig");

pub const Effects = struct {
    context: *anyopaque,
    publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
};

pub const DeliverClipboardImageCompletionHandler = struct {
    effects: Effects,

    /// Keeps expected and stale results quiet while translating classified
    /// media failures into bounded notifications.
    ///
    /// ```zig
    /// try handler.execute(outcome);
    /// ```
    pub fn execute(handler: *DeliverClipboardImageCompletionHandler, outcome: clipboard_image.CompletionOutcome) !void {
        const input: notification_capability.Input = switch (outcome) {
            .applied, .stale, .ignored, .no_image => return,
            .too_large => .{
                .level = .failure,
                .title = "Image preview skipped",
                .message = "The clipboard image exceeds Telar's local preview limit",
            },
            .worker_failed, .adoption_failed => |err| .{
                .level = .failure,
                .title = "Image preview failed",
                .message = @errorName(err),
            },
        };

        try handler.effects.publish_notification(handler.effects.context, input);
    }
};

const Capture = struct {
    calls: usize = 0,
    input: ?notification_capability.Input = null,
    fail: bool = false,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .publish_notification = publishNotification };
    }

    fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.input = input;

        if (capture.fail) {
            return error.NotificationPublicationFailed;
        }
    }
};

fn deliveryHandler(capture: *Capture) DeliverClipboardImageCompletionHandler {
    return .{ .effects = capture.effects() };
}

test "DeliverClipboardImageCompletionHandler keeps successful and obsolete outcomes quiet" {
    var capture: Capture = .{};
    var handler = deliveryHandler(&capture);

    try handler.execute(.applied);
    try handler.execute(.stale);
    try handler.execute(.ignored);
    try handler.execute(.no_image);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "DeliverClipboardImageCompletionHandler maps classified failures to notifications" {
    var capture: Capture = .{};
    var handler = deliveryHandler(&capture);

    try handler.execute(.too_large);

    try std.testing.expectEqual(notification_capability.Level.failure, capture.input.?.level);
    try std.testing.expectEqualStrings("Image preview skipped", capture.input.?.title);
    try std.testing.expectEqualStrings(
        "The clipboard image exceeds Telar's local preview limit",
        capture.input.?.message,
    );

    try handler.execute(.{ .worker_failed = error.ClipboardReadFailed });

    try std.testing.expectEqualStrings("Image preview failed", capture.input.?.title);
    try std.testing.expectEqualStrings("ClipboardReadFailed", capture.input.?.message);

    try handler.execute(.{ .adoption_failed = error.AttachmentAdoptionFailed });

    try std.testing.expectEqualStrings("Image preview failed", capture.input.?.title);
    try std.testing.expectEqualStrings("AttachmentAdoptionFailed", capture.input.?.message);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
}

test "DeliverClipboardImageCompletionHandler propagates notification failure" {
    var capture: Capture = .{ .fail = true };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.NotificationPublicationFailed, handler.execute(.too_large));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
