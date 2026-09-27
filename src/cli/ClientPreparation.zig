const client = @import("telar-client");
const std = @import("std");
const RunOptions = @import("arguments/RunOptions.zig");
const LaunchDefaults = client.LaunchDefaults;
const Preparation = @This();

process: std.process.Init,
options: *const RunOptions,
endpoint: []const u8,
remote_defaults: ?LaunchDefaults = null,
