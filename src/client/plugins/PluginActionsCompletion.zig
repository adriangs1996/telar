const PluginExecutionIdType = @import("../model/types.zig").PluginExecutionId;
const WorkerResultType = @import("WorkerResult.zig");
const Completion = @This();

execution_id: PluginExecutionIdType,
result: anyerror!WorkerResultType,
