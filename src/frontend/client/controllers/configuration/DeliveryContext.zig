const DeliveryContext = @This();
const Client = @import("../../Client.zig");
const source_namespace = @import("config_reloads.zig");
client: *Client,
adoption: ?source_namespace.Adoption = null,

pub fn releaseOwned(context: *DeliveryContext) void {
    if (context.adoption) |adoption| {
        adoption.deinit(context.client.gpa);
    }
}
