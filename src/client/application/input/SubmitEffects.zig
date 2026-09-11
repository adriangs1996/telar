const SubmitEffects = @This();
const name_prompt = @import("../../root.zig").model.name_prompt;
context: *anyopaque,
submit: *const fn (*anyopaque, name_prompt.Submission) anyerror!bool,
