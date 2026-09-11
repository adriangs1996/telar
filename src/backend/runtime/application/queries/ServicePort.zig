const QueryType = @import("../../../history/Query.zig");
const ServicePort = @This();

context: *anyopaque,
submit_fn: *const fn (*anyopaque, QueryType) bool,

/// Transfers an owned query to the bounded history service. A false result
/// means the service rejected it and retains responsibility for cleanup.
///
/// ```zig
/// const queued = service.submit(query);
/// ```
pub fn submit(service: ServicePort, query: QueryType) bool {
    return service.submit_fn(service.context, query);
}
