const Client = @import("../../Client.zig");
const CaptureType = @import("telar-client").Capture;
const CompletionContext = @This();

client: *Client,
capture: ?*CaptureType = null,
