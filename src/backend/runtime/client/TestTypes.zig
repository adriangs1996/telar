const SendCoordinatorFakeSession = @import("SendCoordinatorFakeSession.zig");
const TestTypes = @This();

pub const Client = u8;
pub const Session = *SendCoordinatorFakeSession;
pub const Completion = @import("FakeCompletion.zig");
pub const Detach = u8;
