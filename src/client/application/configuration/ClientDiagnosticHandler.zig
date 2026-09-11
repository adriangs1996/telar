const ModelType = @import("../../model/Model.zig");
const Replacement = @import("Replacement.zig");
const types = @import("../../model/types.zig");
const ClientDiagnosticHandler = @This();

model: *ModelType,

/// Commits one validated diagnostic, using the explicit fallback only
/// when the primary value is malformed.
///
/// ```zig
/// _ = try handler.replace(.{ .diagnostic = diagnostic });
/// ```
pub fn replace(handler: *ClientDiagnosticHandler, replacement: Replacement) !types.Change {
    return handler.model.replaceDiagnostic(replacement.diagnostic) catch |err| switch (err) {
        error.InvalidClientDiagnostic => if (replacement.invalid_fallback) |fallback|
            handler.model.replaceDiagnostic(fallback)
        else
            error.InvalidClientDiagnostic,
    };
}

/// Clears the current diagnostic without advancing a repeated revision.
///
/// ```zig
/// _ = handler.clear();
/// ```
pub fn clear(handler: *ClientDiagnosticHandler) types.Change {
    return handler.model.clearDiagnostic();
}
