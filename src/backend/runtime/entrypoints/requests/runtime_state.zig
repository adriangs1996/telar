//! Protocol controller for opening a client's level-triggered runtime-state
//! subscription. The normal delivery pump emits current and future revisions.

const GenericRuntimeStateController = @import("GenericRuntimeStateController.zig").Type;
const RuntimeStateStubSubscriber = @import("RuntimeStateStubSubscriber.zig");
const std = @import("std");

const TestController = GenericRuntimeStateController(*RuntimeStateStubSubscriber);

test "Controller routes every runtime-state request to the client subscription" {
    var stub: RuntimeStateStubSubscriber = .{};
    var controller = TestController.init(&stub);

    try controller.requestRuntimeState(@enumFromInt(7));
    try controller.requestRuntimeState(@enumFromInt(7));

    try std.testing.expectEqual(@as(usize, 2), stub.call_count);
}
