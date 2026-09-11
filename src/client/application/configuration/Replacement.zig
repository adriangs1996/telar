const DiagnosticType = @import("../../config/Diagnostic.zig");
const Replacement = @This();

diagnostic: DiagnosticType,
invalid_fallback: ?DiagnosticType = null,
