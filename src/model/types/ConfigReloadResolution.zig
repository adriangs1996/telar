const Diagnostic = @import("../config/Diagnostic.zig");

pub const ConfigReloadResolution = union(enum) {
    unchanged,
    rejected: Diagnostic,
    adopted,
};
