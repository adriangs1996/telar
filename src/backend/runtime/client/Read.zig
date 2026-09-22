const core = @import("telar-core");
const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const Read = @This();

io: std.Io,
key: ClientKey,
connection: *core.SocketChannel,
buffer: []u8,
