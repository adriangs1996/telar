const std = @import("std");
const TestOrigin = @This();

listener: std.Io.net.Server,
port: u16
