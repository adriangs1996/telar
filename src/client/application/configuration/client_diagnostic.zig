//! Application policy for the shared bounded client diagnostic banner.

const DiagnosticType = @import("../../config/Diagnostic.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const ClientDiagnosticHandler = @import("ClientDiagnosticHandler.zig");
const VersionType = @import("../../model/Version.zig");

/// Formats one bounded diagnostic value without mutating client state.
///
/// ```zig
/// const diagnostic = formatted("plugin failed: {s}", .{@errorName(err)});
/// ```
pub fn formatted(comptime format: []const u8, args: anytype) DiagnosticType {
    var diagnostic: DiagnosticType = .{};
    diagnostic.set(format, args);

    return diagnostic;
}

fn invalidDiagnostic() DiagnosticType {
    var diagnostic: DiagnosticType = .{};
    diagnostic.buffer[0] = 0xff;
    diagnostic.len = 1;

    return diagnostic;
}

fn oversizedDiagnostic() DiagnosticType {
    var diagnostic: DiagnosticType = .{};
    diagnostic.len = diagnostic.buffer.len + 1;

    return diagnostic;
}

test "ClientDiagnosticHandler commits valid text once" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };
    const diagnostic = formatted("plugin failed: {s}", .{"denied"});

    try std.testing.expect(try handler.replace(.{ .diagnostic = diagnostic }) == .changed);
    try std.testing.expect(try handler.replace(.{ .diagnostic = diagnostic }) == .unchanged);

    try std.testing.expectEqualStrings("plugin failed: denied", model.diagnostic().?);
    try std.testing.expectEqual(VersionType{ .diagnostic = 1 }, model.version());
}

test "ClientDiagnosticHandler replaces an oversized value with an explicit fallback" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };

    try std.testing.expect(try handler.replace(.{
        .diagnostic = oversizedDiagnostic(),
        .invalid_fallback = formatted("configuration failed", .{}),
    }) == .changed);

    try std.testing.expectEqualStrings("configuration failed", model.diagnostic().?);
    try std.testing.expectEqual(VersionType{ .diagnostic = 1 }, model.version());
}

test "ClientDiagnosticHandler preserves state when primary and fallback are malformed" {
    var model = ModelType.init(std.testing.allocator, true);
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ClientDiagnosticHandler = .{ .model = &model };
    _ = try handler.replace(.{ .diagnostic = formatted("resolved", .{}) });

    try std.testing.expect(handler.clear() == .changed);
    try std.testing.expect(handler.clear() == .unchanged);

    try std.testing.expect(model.diagnostic() == null);
    try std.testing.expectEqual(VersionType{ .diagnostic = 2 }, model.version());
}
