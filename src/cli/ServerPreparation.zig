const Preparation = @This();
const std = @import("std");
const source_namespace = @import("server.zig");
process: std.process.Init,
options: source_namespace.ServerOptions,
connector: source_namespace.RuntimeConnector,
