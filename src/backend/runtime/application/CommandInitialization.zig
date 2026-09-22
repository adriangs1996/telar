const core = @import("telar-core");
const std = @import("std");
const ChildEnvironmentType = @import("../../pty/ChildEnvironment.zig");
const CommandInitialization = @This();

gpa: std.mem.Allocator,
launch: core.LaunchView,
cwd_path: []const u8,
environment: *const ChildEnvironmentType,
