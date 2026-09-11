const std = @import("std");
const Target = @This();

host: std.Io.net.HostName,
port: u16,
