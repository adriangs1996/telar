const CommandInitialization = @This();
const std = @import("std");
const source_namespace = @import("pane_launcher.zig");
const pty = @import("../../pty/root.zig");
gpa: std.mem.Allocator,
launch: source_namespace.schema.LaunchView,
cwd_path: []const u8,
environment: *const pty.ChildEnvironment,
