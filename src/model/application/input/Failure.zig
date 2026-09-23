const Diagnostic = @import("../../config/Diagnostic.zig");
const Failure = @This();

reason: anyerror,
diagnostic: Diagnostic,
