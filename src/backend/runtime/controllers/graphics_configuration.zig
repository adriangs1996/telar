//! Protocol controller for one client's graphics transport declaration. The
//! command has no management response and allocates no resources.

const std = @import("std");
const core = @import("telar-core");
const graphics_configuration_commands = @import("../commands/graphics_configuration.zig");

const schema = core.schema;

/// Builds a statically dispatched graphics configuration controller.
///
/// ```zig
/// const GraphicsConfigurationController = Controller(*graphics_configuration_commands.ConfigureGraphicsHandler);
/// var controller = GraphicsConfigurationController.init(&handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        executor: Executor,

        /// Creates one controller bound to the requesting client's handler.
        ///
        /// ```zig
        /// var controller = GraphicsConfigurationController.init(&handler);
        /// ```
        pub fn init(executor: Executor) Self {
            return .{ .executor = executor };
        }

        /// Maps the wire declaration exactly; inheritance and existing-pane
        /// updates remain one aggregate command.
        ///
        /// ```zig
        /// try controller.configureGraphics(configure);
        /// ```
        pub inline fn configureGraphics(controller: *Self, configure: schema.ConfigureGraphics) !void {
            _ = try controller.executor.execute(.{ .shared = configure.shared });
        }
    };
}

const StubExecutor = struct {
    result: graphics_configuration_commands.ConfigureGraphicsResult = .changed,
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?graphics_configuration_commands.ConfigureGraphics = null,

    fn execute(stub: *StubExecutor, command: graphics_configuration_commands.ConfigureGraphics) !graphics_configuration_commands.ConfigureGraphicsResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

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
