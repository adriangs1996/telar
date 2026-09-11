//! Protocol controller for one client's graphics transport declaration. The
//! command has no management response and allocates no resources.

const GenericGraphicsConfigurationController = @import("GenericGraphicsConfigurationController.zig").Type;
const GraphicsConfigurationStubExecutor = @import("GraphicsConfigurationStubExecutor.zig");
const std = @import("std");

const TestController = GenericGraphicsConfigurationController(*GraphicsConfigurationStubExecutor);

test "Controller maps both graphics transport declarations exactly" {
    for ([_]bool{ false, true }) |shared| {
        var stub: GraphicsConfigurationStubExecutor = .{};
        var controller = TestController.init(&stub);

        try controller.configureGraphics(.{ .shared = shared });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(shared, stub.command.?.shared);
    }
}

test "Controller accepts an idempotent graphics configuration result" {
    var stub: GraphicsConfigurationStubExecutor = .{ .result = .unchanged };
    var controller = TestController.init(&stub);

    try controller.configureGraphics(.{ .shared = true });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
}

test "Controller propagates graphics configuration infrastructure failures" {
    var stub: GraphicsConfigurationStubExecutor = .{ .failure = error.GraphicsConfigurationUnavailable };
    var controller = TestController.init(&stub);

    try std.testing.expectError(
        error.GraphicsConfigurationUnavailable,
        controller.configureGraphics(.{ .shared = true }),
    );

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
}
