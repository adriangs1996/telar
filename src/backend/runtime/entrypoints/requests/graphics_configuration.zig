//! Protocol controller for one client's graphics transport declaration. The
//! command has no management response and allocates no resources.

const std = @import("std");
const core = @import("telar-core");
const graphics_configuration_commands = @import("../../application/commands/graphics_configuration.zig");

pub const schema = core.schema;

pub const Controller = @import("GenericGraphicsConfigurationController.zig").Type;

const StubExecutor = @import("GraphicsConfigurationStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps both graphics transport declarations exactly" {
    for ([_]bool{ false, true }) |shared| {
        var stub: StubExecutor = .{};
        var controller = TestController.init(&stub);

        try controller.configureGraphics(.{ .shared = shared });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(shared, stub.command.?.shared);
    }
}

test "Controller accepts an idempotent graphics configuration result" {
    var stub: StubExecutor = .{ .result = .unchanged };
    var controller = TestController.init(&stub);

    try controller.configureGraphics(.{ .shared = true });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
}

test "Controller propagates graphics configuration infrastructure failures" {
    var stub: StubExecutor = .{ .failure = error.GraphicsConfigurationUnavailable };
    var controller = TestController.init(&stub);

    try std.testing.expectError(
        error.GraphicsConfigurationUnavailable,
        controller.configureGraphics(.{ .shared = true }),
    );

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
}
