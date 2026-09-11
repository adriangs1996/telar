const Write = @This();
const source_namespace = @import("session_support.zig");
const core = @import("telar-core");
io: source_namespace.Io,
key: source_namespace.Key,
connection: *core.transport.SocketChannel,
payload: []const u8,
