//! Runtime connection state owned by one client.

pub const outbox = @import("telar-client").connection.outbox;
pub const request_lifecycle = @import("request_lifecycle.zig");
pub const requests = @import("telar-client").connection.requests;
pub const runtime_transport = @import("telar-client").connection.runtime_transport;

test {
    _ = outbox;
    _ = request_lifecycle;
    _ = requests;
    _ = runtime_transport;
}
