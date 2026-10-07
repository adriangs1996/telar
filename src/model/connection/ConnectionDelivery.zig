const Registration = @import("Registration.zig");
const outbox_support = @import("outbox_support.zig");

registration: Registration,
message: outbox_support.Message,
