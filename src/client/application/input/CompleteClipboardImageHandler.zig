const CompleteClipboardImageHandler = @This();
const client_model = @import("../../root.zig").model;
const CompletionEffects = @import("ClipboardImageCompletionEffects.zig");
const CompletionDelivery = @import("ClipboardImageCompletionDelivery.zig");
const source_namespace = @import("clipboard_image.zig");
const std = @import("std");
model: *client_model.Model,
effects: CompletionEffects,
delivery: CompletionDelivery,

/// Consumes one exact completion before validating or applying its image.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *CompleteClipboardImageHandler, command: source_namespace.CompletionCommand) !source_namespace.CompletionOutcome {
    const capture = handler.model.finishClipboardCapture(command.executionId()) orelse
        return handler.deliver(.ignored);

    return handler.deliver(switch (command) {
        .failed => |failure| source_namespace.classifyFailure(failure.reason),
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

fn deliver(handler: *CompleteClipboardImageHandler, outcome: source_namespace.CompletionOutcome) !source_namespace.CompletionOutcome {
    try handler.delivery.deliver(handler.delivery.context, outcome);

    return outcome;
}
