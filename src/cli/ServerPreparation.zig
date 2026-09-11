const std = @import("std");
const ServerOptionsType = @import("arguments/ServerOptions.zig");
const RuntimeConnectorType = @import("RuntimeConnector.zig");
const Preparation = @This();

process: std.process.Init,
options: ServerOptionsType,
connector: RuntimeConnectorType,
