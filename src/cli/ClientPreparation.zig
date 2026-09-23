const std = @import("std");
const RunOptions = @import("arguments/RunOptions.zig");
const LaunchDefaults = @import("LaunchDefaults.zig");
const Preparation = @This();

process: std.process.Init,
options: *const RunOptions,
endpoint: []const u8,
remote_defaults: ?LaunchDefaults = null,
