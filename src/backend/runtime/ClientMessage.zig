const ClientMessage = @This();
const client_session = @import("client/root.zig").session;
client: client_session.Key,
result: anyerror![]u8,
