const Initialization = @This();
const source_namespace = @import("observer_support.zig");
const std = @import("std");
const agent_detection = @import("agent_detection.zig");
const core = @import("telar-core");
io: source_namespace.Io,
gpa: std.mem.Allocator,
cwd: []const u8,
size: source_namespace.schema.TerminalSize,
manifests: *const agent_detection.Table = &core.agent_manifest.builtin_table,
capture_output: bool = false,
