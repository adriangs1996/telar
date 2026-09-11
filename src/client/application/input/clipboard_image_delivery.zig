//! Application policy for delivering one classified clipboard image result.

const ClipboardImageDeliveryCapture = @import("ClipboardImageDeliveryCapture.zig");
const DeliverClipboardImageCompletionHandler = @import("DeliverClipboardImageCompletionHandler.zig");
const std = @import("std");
const notification_capability = @import("../../notifications/notifications.zig");

fn deliveryHandler(capture: *ClipboardImageDeliveryCapture) DeliverClipboardImageCompletionHandler {
    return .{ .effects = capture.effects() };
}

test "DeliverClipboardImageCompletionHandler keeps successful and obsolete outcomes quiet" {
    var capture: ClipboardImageDeliveryCapture = .{};
    var handler = deliveryHandler(&capture);

    try handler.execute(.applied);
    try handler.execute(.stale);
    try handler.execute(.ignored);
    try handler.execute(.no_image);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "DeliverClipboardImageCompletionHandler maps classified failures to notifications" {
    var capture: ClipboardImageDeliveryCapture = .{};
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
    var capture: ClipboardImageDeliveryCapture = .{ .fail = true };
    var handler = deliveryHandler(&capture);

    try std.testing.expectError(error.NotificationPublicationFailed, handler.execute(.too_large));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
