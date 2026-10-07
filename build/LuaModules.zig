const std = @import("std");

/// The vendored C API and the metered runtime built on top of it.
api: *std.Build.Module,
telar: *std.Build.Module,
