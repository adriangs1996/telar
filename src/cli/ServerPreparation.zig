const client = @import("telar-client");
const std = @import("std");
const ServerOptions = @import("arguments/ServerOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const Preparation = @This();

process: std.process.Init,
options: ServerOptions,
connector: RuntimeConnector,
