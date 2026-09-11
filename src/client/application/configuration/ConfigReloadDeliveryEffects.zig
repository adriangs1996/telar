const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const Effects = @This();

context: *anyopaque,
apply_adoption: *const fn (*anyopaque) anyerror!ConfigurationCommitType,
publish_notification: *const fn (*anyopaque, InputType) anyerror!void,
rearm: *const fn (*anyopaque) anyerror!void,
