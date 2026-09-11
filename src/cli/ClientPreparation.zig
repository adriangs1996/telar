const Preparation = @This();
const std = @import("std");
const source_namespace = @import("client.zig");
const remote = @import("remote.zig");
process: std.process.Init,
options: *const source_namespace.RunOptions,
endpoint: []const u8,
remote_defaults: ?remote.LaunchDefaults = null,
