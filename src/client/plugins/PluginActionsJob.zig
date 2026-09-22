const data = @import("model");
const WorkerRequestType = @import("WorkerRequest.zig");
const Job = @This();

execution_id: data.PluginExecutionId,
request: WorkerRequestType,
