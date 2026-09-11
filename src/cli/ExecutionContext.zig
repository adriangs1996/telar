const std = @import("std");
const ExecutionContext = @This();

writer: *std.Io.Writer,
environ: std.process.Environ,
