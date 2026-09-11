const Job = @This();
const client_model = @import("telar-client").model;
const plugin_broker = @import("../../../plugins/root.zig");
execution_id: client_model.PluginExecutionId,
request: plugin_broker.WorkerRequest,
