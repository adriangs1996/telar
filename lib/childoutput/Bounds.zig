const std = @import("std");
const Bound = @import("Bound.zig").Bound;
/// What `ChildOutput.collect` keeps of each stream, and how long it waits.
const Bounds = @This();

stdout: Bound,
stderr: Bound,
/// One deadline for the whole read; a duration counts from `collect`.
timeout: std.Io.Timeout = .none,
