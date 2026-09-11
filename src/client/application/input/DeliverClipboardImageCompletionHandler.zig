const DeliverClipboardImageCompletionHandler = @This();
const Effects = @import("ClipboardImageDeliveryEffects.zig");
const clipboard_image = @import("clipboard_image.zig");
const notification_capability = @import("../../root.zig").notifications;
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
