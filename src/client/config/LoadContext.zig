const std = @import("std");
const DiagnosticType = @import("Diagnostic.zig");
const LoadContext = @This();

gpa: std.mem.Allocator,
io: std.Io,
diagnostic: *DiagnosticType,
