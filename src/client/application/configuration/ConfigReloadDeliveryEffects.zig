const Effects = @This();
const client_model = @import("../../root.zig").model;
const notification_capability = @import("../../root.zig").notifications;
context: *anyopaque,
apply_adoption: *const fn (*anyopaque) anyerror!client_model.ConfigurationCommit,
publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
rearm: *const fn (*anyopaque) anyerror!void,
