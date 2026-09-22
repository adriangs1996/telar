const DiagnosticType = @import("../../config/Diagnostic.zig");
const Failure = @This();

reason: anyerror,
diagnostic: DiagnosticType,
