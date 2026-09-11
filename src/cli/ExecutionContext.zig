const ExecutionContext = @This();
const source_namespace = @import("control.zig");
const std = @import("std");
writer: *source_namespace.Io.Writer,
environ: std.process.Environ,
