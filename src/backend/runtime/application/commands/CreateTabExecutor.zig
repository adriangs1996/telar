const CreateTabExecutor = @This();
const CreateTab = @import("CreateTab.zig");
const CreateTabResult = @import("CreateTabResult.zig");
context: *anyopaque,
execute_fn: *const fn (*anyopaque, CreateTab) anyerror!CreateTabResult,

/// Executes tab creation through the bound application handler.
///
/// ```zig
/// const result = try executor.execute(command);
/// ```
pub fn execute(executor: CreateTabExecutor, command: CreateTab) !CreateTabResult {
    return executor.execute_fn(executor.context, command);
}
