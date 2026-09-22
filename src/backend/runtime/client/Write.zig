const core = @import("telar-core");
const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const Write = @This();

io: std.Io,
key: ClientKey,
connection: *core.SocketChannel,
payload: []const u8,
