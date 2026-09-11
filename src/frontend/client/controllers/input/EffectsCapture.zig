const EffectsCapture = @This();
const source_namespace = @import("name_prompts.zig");
const prompt_state = @import("telar-client").model.name_prompt;
accept: bool = true,
calls: usize = 0,

pub fn port(capture: *EffectsCapture) source_namespace.name_prompt.SubmitEffects {
    return .{ .context = capture, .submit = submitPrompt };
}

fn submitPrompt(context: *anyopaque, submission: prompt_state.Submission) !bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = submission;
    capture.calls += 1;
    return capture.accept;
}
