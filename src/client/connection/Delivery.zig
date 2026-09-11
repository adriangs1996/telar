const Delivery = @This();
const Registration = @import("Registration.zig");
const runtime_transport = @import("runtime_transport.zig");
registration: Registration,
message: runtime_transport.Message,
