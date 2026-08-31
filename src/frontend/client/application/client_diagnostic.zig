//! Application policy for the shared bounded client diagnostic banner.

const std = @import("std");
const lua_config = @import("../../config/root.zig");
const client_model = @import("../model.zig");

pub const Replacement = struct {
    diagnostic: lua_config.Diagnostic,
    invalid_fallback: ?lua_config.Diagnostic = null,
};

/// Formats one bounded diagnostic value without mutating client state.
///
/// ```zig
/// const diagnostic = formatted("plugin failed: {s}", .{@errorName(err)});
/// ```
pub fn formatted(comptime format: []const u8, args: anytype) lua_config.Diagnostic {
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set(format, args);

    return diagnostic;
}

pub const ClientDiagnosticHandler = struct {
    model: *client_model.Model,

    /// Commits one validated diagnostic, using the explicit fallback only
    /// when the primary value is malformed.
    ///
    /// ```zig
    /// _ = try handler.replace(.{ .diagnostic = diagnostic });
    /// ```
    pub fn replace(handler: *ClientDiagnosticHandler, replacement: Replacement) !client_model.Change {
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
    pub fn clear(handler: *ClientDiagnosticHandler) client_model.Change {
        return handler.model.clearDiagnostic();
    }
};

fn invalidDiagnostic() lua_config.Diagnostic {
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.buffer[0] = 0xff;
    diagnostic.len = 1;

    return diagnostic;
}

fn oversizedDiagnostic() lua_config.Diagnostic {
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.len = diagnostic.buffer.len + 1;

    return diagnostic;
}

test "ClientDiagnosticHandler commits valid text once" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };
    const diagnostic = formatted("plugin failed: {s}", .{"denied"});

    try std.testing.expect(try handler.replace(.{ .diagnostic = diagnostic }) == .changed);
    try std.testing.expect(try handler.replace(.{ .diagnostic = diagnostic }) == .unchanged);

    try std.testing.expectEqualStrings("plugin failed: denied", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}

test "ClientDiagnosticHandler replaces an oversized value with an explicit fallback" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };

    try std.testing.expect(try handler.replace(.{
        .diagnostic = oversizedDiagnostic(),
        .invalid_fallback = formatted("configuration failed", .{}),
    }) == .changed);

    try std.testing.expectEqualStrings("configuration failed", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}

test "ClientDiagnosticHandler preserves state when primary and fallback are malformed" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };
    _ = try handler.replace(.{ .diagnostic = formatted("preserved", .{}) });
    const version = model.version();

    try std.testing.expectError(error.InvalidClientDiagnostic, handler.replace(.{
        .diagnostic = invalidDiagnostic(),
        .invalid_fallback = invalidDiagnostic(),
    }));

    try std.testing.expectEqualStrings("preserved", model.diagnostic().?);
    try std.testing.expectEqualDeep(version, model.version());
}

test "ClientDiagnosticHandler clears visible text once" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };
    _ = try handler.replace(.{ .diagnostic = formatted("resolved", .{}) });

    try std.testing.expect(handler.clear() == .changed);
    try std.testing.expect(handler.clear() == .unchanged);

    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 2 }, model.version());
}
