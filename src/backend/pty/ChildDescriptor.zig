const std = @import("std");
const spawn = @import("spawn.zig");
const ChildDescriptor = @This();

error_fd: std.c.fd_t,
source: std.c.fd_t,
target: std.c.fd_t,
stage: spawn.ChildFailureStage,
