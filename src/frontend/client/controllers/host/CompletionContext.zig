const CompletionContext = @This();
const Client = @import("../../Client.zig");
const attachments = @import("../../../attachments/root.zig");
client: *Client,
capture: ?*attachments.Capture = null,
