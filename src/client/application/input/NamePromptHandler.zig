const NamePromptHandler = @This();
const name_prompt = @import("../../root.zig").model.name_prompt;
const SubmitEffects = @import("SubmitEffects.zig");
const source_namespace = @import("name_prompt.zig");
const std = @import("std");
prompt: *name_prompt.State,
effects: SubmitEffects,

/// Applies one editor command and closes the prompt only after its submit
/// effect accepts the borrowed submission.
///
/// ```zig
/// const outcome = try handler.execute(.submit);
/// ```
pub fn execute(handler: *NamePromptHandler, command: name_prompt.Command) !source_namespace.Outcome {
    return switch (handler.prompt.apply(command)) {
        .unchanged => .unchanged,
        .routing_changed => .routing_changed,
        .changed => .changed,
        .cancelled => .cancelled,
        .removed => .removed,
        .submitted => |submission| if (!try handler.effects.submit(
            handler.effects.context,
            submission,
        ))
            .blocked
        else blk: {
            std.debug.assert(handler.prompt.finish(submission.target));
            break :blk .finished;
        },
    };
}
