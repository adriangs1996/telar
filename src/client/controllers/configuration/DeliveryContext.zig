const Client = @import("../../AttachedClient.zig");
const AdoptionType = @import("../../resources/Adoption.zig");
const DeliveryContext = @This();

client: *Client,
adoption: ?AdoptionType = null,

pub fn releaseOwned(context: *DeliveryContext) void {
    if (context.adoption) |adoption| {
        adoption.deinit(context.client.gpa);
    }
}
