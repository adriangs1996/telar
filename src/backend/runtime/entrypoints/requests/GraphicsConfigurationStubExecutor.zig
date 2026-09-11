const graphics_configuration_commands = @import("../../application/commands/graphics_configuration.zig");
const ConfigureGraphicsType = @import("../../application/commands/ConfigureGraphics.zig");
const StubExecutor = @This();

result: graphics_configuration_commands.ConfigureGraphicsResult = .changed,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?ConfigureGraphicsType = null,

pub fn execute(stub: *StubExecutor, command: ConfigureGraphicsType) !graphics_configuration_commands.ConfigureGraphicsResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
