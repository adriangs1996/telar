const id = @import("schema/id.zig");
const ClientDescriptor = @import("ClientDescriptor.zig");

pub const capacity = 8;
request_id: id.RequestId,
entries: [capacity]ClientDescriptor = undefined,
count: u8 = 0,
