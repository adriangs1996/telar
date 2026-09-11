const std = @import("std");
const Spawned = @This();

master: std.c.fd_t,
pid: std.c.pid_t,
