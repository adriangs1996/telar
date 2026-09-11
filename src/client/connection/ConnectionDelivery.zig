const Registration = @import("Registration.zig");
const outbox_support = @import("outbox_support.zig");
const Delivery = @This();

registration: Registration,
message: outbox_support.Message,
