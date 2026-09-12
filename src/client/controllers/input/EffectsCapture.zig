const SubmitEffectsType = @import("../../application/input/SubmitEffects.zig");
const SubmissionType = @import("../../model/Submission.zig");
const EffectsCapture = @This();

accept: bool = true,
calls: usize = 0,

pub fn port(capture: *EffectsCapture) SubmitEffectsType {
    return .{ .context = capture, .submit = submitPrompt };
}

fn submitPrompt(context: *anyopaque, submission: SubmissionType) !bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = submission;
    capture.calls += 1;
    return capture.accept;
}
