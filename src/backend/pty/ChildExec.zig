const std = @import("std");
const Command = @import("Command.zig");
const ChildExec = @This();

master: std.c.fd_t,
slave: std.c.fd_t,
cwd_fd: ?std.c.fd_t,
error_fd: std.c.fd_t,
command: *const Command,
environment: [*:null]const ?[*:0]const u8,
path: []const u8,
