const Client = @import("../../Client.zig");
const PluginActionType = @import("telar-client").PluginAction;
const CallbackContextType = @import("telar-client").CallbackContext;
const WorkerRequestType = @import("../../../plugins/WorkerRequest.zig");
const StartContext = @This();

client: *Client,
requested: PluginActionType,
callback_context: CallbackContextType,
request: ?WorkerRequestType = null,
