const std = @import("std");
const AuthorityCommand = @This();

init: std.process.Init,
writer: *std.Io.Writer,
