const StubExecutor = @This();
const graphics_credit_commands = @import("../../application/commands/graphics_credit.zig");
result: graphics_credit_commands.ReturnGraphicsCreditResult = .returned,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?graphics_credit_commands.ReturnGraphicsCredit = null,

pub fn execute(stub: *StubExecutor, command: graphics_credit_commands.ReturnGraphicsCredit) !graphics_credit_commands.ReturnGraphicsCreditResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
