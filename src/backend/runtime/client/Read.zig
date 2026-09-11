const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const Read = @This();

io: std.Io,
key: ClientKey,
connection: *SocketChannelType,
buffer: []u8,
