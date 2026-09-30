const std = @import("std");
const Bound = @import("Bound.zig").Bound;
/// What `ChildOutput.collect` keeps of each stream, and how long it waits.
const Bounds = @This();

stdout: Bound,
stderr: Bound,
timeout: std.Io.Timeout = .none,
