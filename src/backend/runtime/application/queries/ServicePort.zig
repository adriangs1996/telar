const ServicePort = @This();
const source_namespace = @import("history.zig");
context: *anyopaque,
submit_fn: *const fn (*anyopaque, source_namespace.Query) bool,

/// Transfers an owned query to the bounded history service. A false result
/// means the service rejected it and retains responsibility for cleanup.
///
/// ```zig
/// const queued = service.submit(query);
/// ```
pub fn submit(service: ServicePort, query: source_namespace.Query) bool {
    return service.submit_fn(service.context, query);
}
