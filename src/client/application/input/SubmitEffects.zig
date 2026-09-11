const SubmissionType = @import("../../model/Submission.zig");
const SubmitEffects = @This();

context: *anyopaque,
submit: *const fn (*anyopaque, SubmissionType) anyerror!bool,
