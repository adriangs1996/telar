const ChildExec = @This();
const std = @import("std");
const source_namespace = @import("spawn.zig");
master: std.c.fd_t,
slave: std.c.fd_t,
cwd_fd: ?std.c.fd_t,
error_fd: std.c.fd_t,
command: *const source_namespace.Command,
environment: [*:null]const ?[*:0]const u8,
path: []const u8,
