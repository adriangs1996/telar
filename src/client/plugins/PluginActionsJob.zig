const PluginExecutionIdType = @import("../model/types.zig").PluginExecutionId;
const WorkerRequestType = @import("WorkerRequest.zig");
const Job = @This();

execution_id: PluginExecutionIdType,
request: WorkerRequestType,
