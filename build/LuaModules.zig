const std = @import("std");
const LuaModules = @This();

/// The vendored C API and the metered runtime built on top of it.
api: *std.Build.Module,
telar: *std.Build.Module,
