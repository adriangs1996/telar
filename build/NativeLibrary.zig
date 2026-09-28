//! How a C library that a library links reaches the graph: compiled from
//! sources pinned in `build.zig.zon`, or found on the system.
const std = @import("std");

/// The name passed to `linkSystemLibrary`, such as `brotlidec`.
library: []const u8,
source: Source,

const Source = union(enum) {
    /// A static library that carries its public headers.
    built: *std.Build.Step.Compile,
    /// A system installation: the prefix holding `include/` and `lib/`, or
    /// null for the default search paths.
    system: ?[]const u8,
};
