//! Adapts client diagnostic producers to the shared application handler.

const lua_config = @import("../config/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const client_diagnostic = client_application.client_diagnostic;

pub const Replacement = client_diagnostic.Replacement;

/// Formats one bounded diagnostic value for a later replacement.
///
/// ```zig
/// const diagnostic = formatted("plugin failed: {s}", .{@errorName(err)});
/// ```
pub fn formatted(comptime format: []const u8, args: anytype) lua_config.Diagnostic {
    return client_diagnostic.formatted(format, args);
}

/// Commits a validated diagnostic and its optional malformed-value fallback.
///
/// ```zig
/// _ = try replace(client, .{ .diagnostic = diagnostic });
/// ```
pub fn replace(client: *Client, replacement: Replacement) !client_model.Change {
    var use_case: client_diagnostic.ClientDiagnosticHandler = .{ .model = &client.model };

    return use_case.replace(replacement);
}

/// Formats and commits one diagnostic that needs no malformed-value fallback.
///
/// ```zig
/// _ = try set(client, "plugin failed: {s}", .{@errorName(err)});
/// ```
pub fn set(client: *Client, comptime format: []const u8, args: anytype) !client_model.Change {
    return replace(client, .{ .diagnostic = formatted(format, args) });
}

/// Clears the current diagnostic through the application boundary.
///
/// ```zig
/// _ = clear(client);
/// ```
pub fn clear(client: *Client) client_model.Change {
    var use_case: client_diagnostic.ClientDiagnosticHandler = .{ .model = &client.model };

    return use_case.clear();
}
