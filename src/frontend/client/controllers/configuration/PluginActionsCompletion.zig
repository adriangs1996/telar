const PluginExecutionIdType = @import("telar-client").PluginExecutionId;
const WorkerResultType = @import("../../../plugins/WorkerResult.zig");
const Completion = @This();

execution_id: PluginExecutionIdType,
result: anyerror!WorkerResultType,
