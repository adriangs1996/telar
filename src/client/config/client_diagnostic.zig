//! Application policy for the shared bounded client diagnostic banner.
const model_data = @import("model");

const Replacement = @import("Replacement.zig");
const std = @import("std");

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

fn invalidDiagnostic() model_data.Diagnostic {
    var diagnostic: model_data.Diagnostic = .{};
    diagnostic.buffer[0] = 0xff;
    diagnostic.len = 1;

    return diagnostic;
}

fn oversizedDiagnostic() model_data.Diagnostic {
    var diagnostic: model_data.Diagnostic = .{};
    diagnostic.len = diagnostic.buffer.len + 1;

    return diagnostic;
}

test "diagnostic commits valid text once" {
    var model = model_data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    const diagnostic = formatted("plugin failed: {s}", .{"denied"});

    try std.testing.expect(try replace(&model, .{ .diagnostic = diagnostic }) == .changed);
    try std.testing.expect(try replace(&model, .{ .diagnostic = diagnostic }) == .unchanged);

    try std.testing.expectEqualStrings("plugin failed: denied", model.diagnostic().?);
    try std.testing.expectEqual(model_data.Version{ .diagnostic = 1 }, model.version());
}

test "diagnostic replaces an oversized value with an explicit fallback" {
    var model = model_data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();

    try std.testing.expect(try replace(&model, .{
        .diagnostic = oversizedDiagnostic(),
        .invalid_fallback = formatted("configuration failed", .{}),
    }) == .changed);

    try std.testing.expectEqualStrings("configuration failed", model.diagnostic().?);
    try std.testing.expectEqual(model_data.Version{ .diagnostic = 1 }, model.version());
}

test "diagnostic preserves state when primary and fallback are malformed" {
    var model = model_data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try replace(&model, .{ .diagnostic = formatted("preserved", .{}) });
    const version = model.version();

    try std.testing.expectError(error.InvalidClientDiagnostic, replace(&model, .{
        .diagnostic = invalidDiagnostic(),
        .invalid_fallback = invalidDiagnostic(),
    }));

    try std.testing.expectEqualStrings("preserved", model.diagnostic().?);
    try std.testing.expectEqualDeep(version, model.version());
}

test "diagnostic clears visible text once" {
    var model = model_data.ClientModel.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try replace(&model, .{ .diagnostic = formatted("resolved", .{}) });

    try std.testing.expect(model.clearDiagnostic() == .changed);
    try std.testing.expect(model.clearDiagnostic() == .unchanged);

    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(model_data.Version{ .diagnostic = 2 }, model.version());
}

/// Validates replacement text before committing. Example: `_ = try replace(model, .{ .diagnostic = value });`.
pub fn replace(model: *model_data.ClientModel, replacement: Replacement) !model_data.Change {
    return model.replaceDiagnostic(replacement.diagnostic) catch |err| switch (err) {
        error.InvalidClientDiagnostic => if (replacement.invalid_fallback) |fallback|
            model.replaceDiagnostic(fallback)
        else
            error.InvalidClientDiagnostic,
    };
}
