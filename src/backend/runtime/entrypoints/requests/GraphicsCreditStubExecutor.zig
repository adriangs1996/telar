const graphics_credit_commands = @import("../../application/commands/graphics_credit.zig");
const ReturnGraphicsCreditType = @import("../../application/commands/ReturnGraphicsCredit.zig");
const StubExecutor = @This();

result: graphics_credit_commands.ReturnGraphicsCreditResult = .returned,
failure: ?anyerror = null,
call_count: usize = 0,
command: ?ReturnGraphicsCreditType = null,

pub fn execute(stub: *StubExecutor, command: ReturnGraphicsCreditType) !graphics_credit_commands.ReturnGraphicsCreditResult {
    stub.call_count += 1;
    stub.command = command;

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result;
}
