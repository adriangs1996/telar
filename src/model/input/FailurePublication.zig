const Diagnostic = @import("../config/Diagnostic.zig");
const FailurePublication = @This();

diagnostic: Diagnostic,
title: []const u8,
