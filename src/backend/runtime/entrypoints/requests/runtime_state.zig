//! Protocol controller for opening a client's level-triggered runtime-state
//! subscription. The normal delivery pump emits current and future revisions.

const std = @import("std");
const schema = @import("telar-core").schema;

pub const Controller = @import("GenericRuntimeStateController.zig").Type;

const StubSubscriber = @import("RuntimeStateStubSubscriber.zig");

const TestController = Controller(*StubSubscriber);

test "Controller routes every runtime-state request to the client subscription" {
    var stub: StubSubscriber = .{};
    var controller = TestController.init(&stub);

    try controller.requestRuntimeState(@enumFromInt(7));
    try controller.requestRuntimeState(@enumFromInt(7));

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
