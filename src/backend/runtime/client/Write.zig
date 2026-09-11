const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const Write = @This();

io: std.Io,
key: ClientKey,
connection: *SocketChannelType,
payload: []const u8,
