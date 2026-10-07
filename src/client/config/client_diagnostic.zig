//! Application policy for the shared bounded client diagnostic banner.
const model_data = @import("model");

const data = @import("model");

/// Formats one bounded diagnostic value without mutating client state.
///
/// ```zig
/// const diagnostic = formatted("plugin failed: {s}", .{@errorName(err)});
/// ```
pub fn formatted(comptime format: []const u8, args: anytype) model_data.Diagnostic {
    var diagnostic: model_data.Diagnostic = .{};
    diagnostic.set(format, args);

    return diagnostic;
}

/// Validates replacement text before committing. Example: `_ = try replace(model, .{ .diagnostic = value });`.
pub fn replace(model: *model_data.ClientModel, replacement: Replacement) !model_data.Change {
    return data.client_diagnostic.replace(model, replacement.diagnostic) catch |err| switch (err) {
        error.InvalidClientDiagnostic => if (replacement.invalid_fallback) |fallback|
            data.client_diagnostic.replace(model, fallback)
        else
            error.InvalidClientDiagnostic,
    };
}

const Replacement = struct {
    diagnostic: data.Diagnostic,
    invalid_fallback: ?data.Diagnostic = null,
};
