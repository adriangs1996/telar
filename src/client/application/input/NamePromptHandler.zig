const NamePromptState = @import("../../model/NamePromptState.zig");
const SubmitEffects = @import("SubmitEffects.zig");
const name_prompt = @import("../../model/name_prompt.zig");
const name_prompt_ops = @import("name_prompt.zig");
const std = @import("std");
const NamePromptHandler = @This();

prompt: *NamePromptState,
effects: SubmitEffects,

/// Applies one editor command and closes the prompt only after its submit
/// effect accepts the borrowed submission.
///
/// ```zig
/// const outcome = try handler.execute(.submit);
/// ```
pub fn execute(handler: *NamePromptHandler, command: name_prompt.Command) !name_prompt_ops.Outcome {
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
