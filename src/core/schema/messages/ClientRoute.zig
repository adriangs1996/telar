const ClientRoute = @This();

id: u64,
generation: u64,

/// Rejects the zero identities reserved for absent client routes.
///
/// ```zig
/// try route.validateWire();
/// ```
pub fn validateWire(route: ClientRoute) !void {
    if (route.id == 0 or route.generation == 0) {
        return error.InvalidClientRoute;
    }
}
