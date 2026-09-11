const ModelType = @import("../../model/Model.zig");
const ClipboardImageCompletionEffects = @import("ClipboardImageCompletionEffects.zig");
const ClipboardImageCompletionDelivery = @import("ClipboardImageCompletionDelivery.zig");
const clipboard_image = @import("clipboard_image.zig");
const std = @import("std");
const CompleteClipboardImageHandler = @This();

model: *ModelType,
effects: ClipboardImageCompletionEffects,
delivery: ClipboardImageCompletionDelivery,

/// Consumes one exact completion before validating or applying its image.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *CompleteClipboardImageHandler, command: clipboard_image.CompletionCommand) !clipboard_image.CompletionOutcome {
    const capture = handler.model.finishClipboardCapture(command.executionId()) orelse
        return handler.deliver(.ignored);

    return handler.deliver(switch (command) {
        .failed => |failure| clipboard_image.classifyFailure(failure.reason),
        .succeeded => |result| result: {
            if (result.result_id != capture.id or !std.meta.eql(result.target, capture.target)) {
                break :result .stale;
            }

            const current = handler.model.focusedAttachmentTarget() orelse
                break :result .stale;
            if (!std.meta.eql(current, capture.target)) {
                break :result .stale;
            }

            const layout_changed = handler.effects.adopt(handler.effects.context) catch |err| {
                break :result .{ .adoption_failed = err };
            };
            if (layout_changed) {
                try handler.effects.resize(handler.effects.context);
            }

            break :result .applied;
        },
    });
}

fn deliver(handler: *CompleteClipboardImageHandler, outcome: clipboard_image.CompletionOutcome) !clipboard_image.CompletionOutcome {
    try handler.delivery.deliver(handler.delivery.context, outcome);

    return outcome;
}
