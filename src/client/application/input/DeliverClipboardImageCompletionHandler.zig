const ClipboardImageDeliveryEffects = @import("ClipboardImageDeliveryEffects.zig");
const clipboard_image = @import("clipboard_image.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const DeliverClipboardImageCompletionHandler = @This();

effects: ClipboardImageDeliveryEffects,

/// Keeps expected and stale results quiet while translating classified
/// media failures into bounded notifications.
///
/// ```zig
/// try handler.execute(outcome);
/// ```
pub fn execute(handler: *DeliverClipboardImageCompletionHandler, outcome: clipboard_image.CompletionOutcome) !void {
    const input: InputType = switch (outcome) {
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
