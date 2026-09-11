const NotificationShown = @This();
const source_namespace = @import("notification_support.zig");
request_id: source_namespace.RequestId,
delivered_clients: u8,
