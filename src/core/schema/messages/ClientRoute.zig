const ClientRoute = @This();

id: u64,
generation: u64,

/// Rejects the zero identities reserved for absent client routes.
///
/// ```zig
/// try route.validateWire();
/// ```
pub fn validateWire(self: ClientRoute) !void {
    if (self.id == 0 or self.generation == 0) {
        return error.InvalidClientRoute;
    }
}
