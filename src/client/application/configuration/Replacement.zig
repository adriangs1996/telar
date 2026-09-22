const data = @import("model");
const Replacement = @This();

diagnostic: data.Diagnostic,
invalid_fallback: ?data.Diagnostic = null,
