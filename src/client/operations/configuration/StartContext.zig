const Client = @import("../../AttachedClient.zig");
const PluginActionType = @import("../../input/PluginAction.zig");
const CallbackContextType = @import("../../config/CallbackContext.zig");
const WorkerRequestType = @import("../../plugins/WorkerRequest.zig");
const StartContext = @This();

client: *Client,
requested: PluginActionType,
callback_context: CallbackContextType,
request: ?WorkerRequestType = null,
