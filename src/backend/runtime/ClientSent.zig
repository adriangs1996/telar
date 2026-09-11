const ClientKey = @import("../history/ClientKey.zig");
const ClientSent = @This();

client: ClientKey,
result: anyerror!void,
