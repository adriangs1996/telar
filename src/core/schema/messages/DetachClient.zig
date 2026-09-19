const id = @import("../id.zig");
const ClientRoute = @import("ClientRoute.zig");
const DetachClient = @This();

request_id: id.RequestId,
client_id: u64,
client_generation: u64,

/// Rejects absent routes before a teardown request is admitted. Example: `try request.validateWire();`
pub fn validateWire(self: DetachClient) !void {
    const route: ClientRoute = .{ .id = self.client_id, .generation = self.client_generation };
    try route.validateWire();
}
