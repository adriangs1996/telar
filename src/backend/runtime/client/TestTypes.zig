const TestTypes = @This();
const FakeSession = @import("SendCoordinatorFakeSession.zig");
const FakeCompletion = @import("FakeCompletion.zig");
pub const Client = u8;
pub const Session = *FakeSession;
pub const Completion = FakeCompletion;
pub const Detach = u8;
