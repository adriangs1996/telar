const DiagnosticType = @import("../../config/Diagnostic.zig");
const FailurePublication = @This();

diagnostic: DiagnosticType,
title: []const u8,
