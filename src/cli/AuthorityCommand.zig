const AuthorityCommand = @This();
const std = @import("std");
const source_namespace = @import("proxy.zig");
init: std.process.Init,
writer: *source_namespace.Io.Writer,
