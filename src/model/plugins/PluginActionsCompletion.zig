//! A plugin worker's outcome. A success leaves its result where the job
//! told the worker to write it, so the completion stays a few words as it
//! crosses the adapter's inbox.
const data = @import("../model.zig");

execution_id: data.PluginExecutionId,
result: anyerror!void,
