const DiagnosticType = @import("../config/Diagnostic.zig");

pub const ConfigReloadResolution = union(enum) {
    unchanged,
    rejected: DiagnosticType,
    adopted,
};
