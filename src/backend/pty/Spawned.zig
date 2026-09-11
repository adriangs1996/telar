const Spawned = @This();
const std = @import("std");
master: std.c.fd_t,
pid: std.c.pid_t,
