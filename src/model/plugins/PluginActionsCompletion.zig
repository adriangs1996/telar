const data = @import("../model.zig");
const WorkerResult = @import("WorkerResult.zig");
const Completion = @This();

execution_id: data.PluginExecutionId,
result: anyerror!WorkerResult,
