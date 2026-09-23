const std = @import("std");
const ServerOptions = @import("arguments/ServerOptions.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const Preparation = @This();

process: std.process.Init,
options: ServerOptions,
connector: RuntimeConnector,
