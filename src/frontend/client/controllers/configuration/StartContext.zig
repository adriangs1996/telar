const StartContext = @This();
const Client = @import("../../Client.zig");
const input = @import("../../../input/root.zig");
const config = @import("../../../config/root.zig");
const plugin_broker = @import("../../../plugins/root.zig");
client: *Client,
requested: input.action.PluginAction,
callback_context: config.CallbackContext,
request: ?plugin_broker.WorkerRequest = null,
