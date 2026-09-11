const PluginExecutionIdType = @import("telar-client").PluginExecutionId;
const WorkerRequestType = @import("../../../plugins/WorkerRequest.zig");
const Job = @This();

execution_id: PluginExecutionIdType,
request: WorkerRequestType,
