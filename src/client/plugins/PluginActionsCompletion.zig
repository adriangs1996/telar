const data = @import("model");
const WorkerResultType = @import("WorkerResult.zig");
const Completion = @This();

execution_id: data.PluginExecutionId,
result: anyerror!WorkerResultType,
