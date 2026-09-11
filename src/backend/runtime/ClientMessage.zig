const ClientKey = @import("../history/ClientKey.zig");
const ClientMessage = @This();

client: ClientKey,
result: anyerror![]u8,
