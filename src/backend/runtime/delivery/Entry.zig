const response_queue = @import("response_queue.zig");
const Entry = @This();

offset: u8,
response: *response_queue.PendingResponse,
