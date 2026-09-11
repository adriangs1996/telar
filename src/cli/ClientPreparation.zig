const std = @import("std");
const RunOptionsType = @import("arguments/RunOptions.zig");
const LaunchDefaultsType = @import("LaunchDefaults.zig");
const Preparation = @This();

process: std.process.Init,
options: *const RunOptionsType,
endpoint: []const u8,
remote_defaults: ?LaunchDefaultsType = null,
