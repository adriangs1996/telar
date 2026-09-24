//! The one diagnostic a client shows: set, replaced and cleared by its source.

const std = @import("std");
const model_data = @import("../model.zig");
const ClientModel = @import("ClientModel.zig");

/// Returns the bounded client diagnostic currently shown in the chrome.
///
/// ```zig
/// const message = client_diagnostic.shown(model) orelse return;
/// ```
pub fn shown(model: *const ClientModel) ?[]const u8 {
    if (model.client_diagnostic.len == 0) {
        return null;
    }

    return model.client_diagnostic.message();
}

/// Replaces the visible diagnostic after validating its bounded text.
///
/// ```zig
/// _ = try client_diagnostic.replace(model, diagnostic);
/// ```
pub fn replace(model: *ClientModel, diagnostic_value: model_data.Diagnostic) !model_data.Change {
    if (diagnostic_value.len > diagnostic_value.buffer.len) {
        return error.InvalidClientDiagnostic;
    }

    const message = diagnostic_value.buffer[0..diagnostic_value.len];
    if (!std.unicode.utf8ValidateSlice(message)) {
        return error.InvalidClientDiagnostic;
    }

    if (message.len == 0) {
        return clear(model);
    }

    if (shown(model)) |current| {
        if (std.mem.eql(u8, current, message)) {
            return .unchanged;
        }
    }

    model.client_diagnostic = diagnostic_value;
    model.diagnostic_revision +%= 1;
    return .changed;
}

/// Formats and commits one bounded client diagnostic.
///
/// ```zig
/// _ = try client_diagnostic.set(model, "callback failed: {s}", .{@errorName(err)});
/// ```
pub fn set(model: *ClientModel, comptime format: []const u8, args: anytype) !model_data.Change {
    var diagnostic_value: model_data.Diagnostic = .{};
    diagnostic_value.set(format, args);

    return replace(model, diagnostic_value);
}

/// Clears the diagnostic only when visible text exists.
///
/// ```zig
/// _ = client_diagnostic.clear(model);
/// ```
pub fn clear(model: *ClientModel) model_data.Change {
    if (model.client_diagnostic.len == 0) {
        return .unchanged;
    }

    model.client_diagnostic.len = 0;
    model.diagnostic_revision +%= 1;
    return .changed;
}
