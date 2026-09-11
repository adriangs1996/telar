const StubExecutor = @This();
const graphics_configuration_commands = @import("../../application/commands/graphics_configuration.zig");
result: graphics_configuration_commands.ConfigureGraphicsResult = .changed,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?graphics_configuration_commands.ConfigureGraphics = null,

pub fn execute(stub: *StubExecutor, command: graphics_configuration_commands.ConfigureGraphics) !graphics_configuration_commands.ConfigureGraphicsResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
