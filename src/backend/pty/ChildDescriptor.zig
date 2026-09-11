const ChildDescriptor = @This();
const std = @import("std");
const source_namespace = @import("spawn.zig");
error_fd: std.c.fd_t,
source: std.c.fd_t,
target: std.c.fd_t,
stage: source_namespace.ChildFailureStage,
