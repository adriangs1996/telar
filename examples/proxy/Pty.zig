const std = @import("std");
const Pty = @This();

master: std.c.fd_t,
slave: std.c.fd_t,
