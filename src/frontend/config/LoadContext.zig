const std = @import("std");
const DiagnosticType = @import("telar-client").Diagnostic;
const LoadContext = @This();

gpa: std.mem.Allocator,
io: std.Io,
diagnostic: *DiagnosticType,
