const Client = @import("../../AttachedClient.zig");
const CaptureType = @import("../../attachments/Capture.zig");
const CompletionContext = @This();

client: *Client,
capture: ?*CaptureType = null,
