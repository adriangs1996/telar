const std = @import("std");
const LaunchViewType = @import("telar-core").LaunchView;
const ChildEnvironmentType = @import("../../pty/ChildEnvironment.zig");
const CommandInitialization = @This();

gpa: std.mem.Allocator,
launch: LaunchViewType,
cwd_path: []const u8,
environment: *const ChildEnvironmentType,
