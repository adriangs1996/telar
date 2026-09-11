const InputType = @import("../../notifications/NotificationInput.zig");
const PublishCommand = @This();

now_ns: u64,
input: InputType,
