const data = @import("model");
const WorkerRequest = @import("WorkerRequest.zig");
const Job = @This();

execution_id: data.PluginExecutionId,
request: WorkerRequest,
