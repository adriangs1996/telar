const std = @import("std");
const Pair = @This();

master: std.c.fd_t,
slave: std.c.fd_t,
