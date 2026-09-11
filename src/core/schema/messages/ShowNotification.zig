const id = @import("../id.zig");
const Notification = @import("Notification.zig");
const ShowNotification = @This();

request_id: id.RequestId,
notification: Notification,
