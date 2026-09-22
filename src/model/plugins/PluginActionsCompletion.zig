const data = @import("../model.zig");
const WorkerResultType = @import("WorkerResult.zig");
const Completion = @This();

execution_id: data.PluginExecutionId,
result: anyerror!WorkerResultType,
