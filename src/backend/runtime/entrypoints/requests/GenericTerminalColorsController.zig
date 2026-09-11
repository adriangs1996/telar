const TerminalColors = @import("telar-core").TerminalColors;

/// Example: `const ColorsController = Controller(*ColorsHandler);`.
pub fn Type(comptime Executor: type) type {
    return struct {
        executor: Executor,

        /// Example: `controller.configureTerminalColors(message);`.
        pub fn configureTerminalColors(controller: *@This(), message: TerminalColors) void {
            controller.executor.execute(message);
        }
    };
}
