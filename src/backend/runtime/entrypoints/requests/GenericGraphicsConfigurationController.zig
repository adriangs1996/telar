const ConfigureGraphicsType = @import("telar-core").ConfigureGraphics;

/// Builds a statically dispatched graphics configuration controller.
///
/// ```zig
/// const GraphicsConfigurationController = Controller(*graphics_configuration_commands.ConfigureGraphicsHandler);
/// var controller = GraphicsConfigurationController.init(&handler);
/// ```
pub fn Type(comptime Executor: type) type {
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
        pub inline fn configureGraphics(controller: *Self, configure: ConfigureGraphicsType) !void {
            _ = try controller.executor.execute(.{ .shared = configure.shared });
        }
    };
}
