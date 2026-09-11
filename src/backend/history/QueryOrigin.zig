const ClientKey = @import("ClientKey.zig");
const QueryOrigin = @This();

client: ClientKey,
close_after_reply: bool,
