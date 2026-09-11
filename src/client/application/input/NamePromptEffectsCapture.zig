const EffectsCapture = @This();
const name_prompt = @import("../../root.zig").model.name_prompt;
const SubmitEffects = @import("SubmitEffects.zig");
prompt: *const name_prompt.State,
accept: bool = true,
fail: bool = false,
calls: usize = 0,
observed_active: bool = false,
name: [32]u8 = undefined,
name_len: u8 = 0,

pub fn port(capture: *EffectsCapture) SubmitEffects {
    return .{ .context = capture, .submit = submit };
}

fn submit(context: *anyopaque, submission: name_prompt.Submission) !bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_active = capture.prompt.active();
    capture.name_len = @intCast(submission.name.len);
    @memcpy(capture.name[0..submission.name.len], submission.name);

    if (capture.fail) {
        return error.SubmitFailed;
    }

    return capture.accept;
}

pub fn nameSlice(capture: *const EffectsCapture) []const u8 {
    return capture.name[0..capture.name_len];
}
