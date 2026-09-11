const schema = @import("telar-core").schema;
/// Example: `const ColorsController = Controller(*ColorsHandler);`.
pub fn Type(comptime Executor: type) type {
    return struct {
        executor: Executor,

        /// Example: `controller.configureTerminalColors(message);`.
        pub fn configureTerminalColors(controller: *@This(), message: schema.ConfigureTerminalColors) void {
            controller.executor.execute(message);
        }
    };
}
