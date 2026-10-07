const response_queue = @import("response_queue.zig");

offset: u8,
response: *response_queue.PendingResponse,
