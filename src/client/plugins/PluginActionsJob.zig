const data = @import("model");
const WorkerRequest = @import("WorkerRequest.zig");
const Job = @This();

execution_id: data.PluginExecutionId,
request: WorkerRequest,
/// Where the worker writes a successful result before its completion posts;
/// the completion carries only the outcome. The client owns it, and one
/// plugin action runs at a time.
result: *data.WorkerResult,
