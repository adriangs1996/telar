//! Client adapters for connection and session lifecycle.

pub const client_detachments = @import("client_detachments.zig");
pub const client_layouts = @import("client_layouts.zig");
pub const client_startup = @import("client_startup.zig");
pub const request_failures = @import("request_failures.zig");
pub const resync_requirements = @import("resync_requirements.zig");

test {
    _ = client_detachments;
    _ = client_layouts;
    _ = client_startup;
    _ = request_failures;
    _ = resync_requirements;
}
