//! Validates Lua action batches and preserves invocation diagnostics.
const data = @import("model");
const Registry = @import("../../plugins/Registry.zig");

/// Preserves the VM diagnostic or supplies the invocation error.
/// Example: `const outcome = lua_actions.invocationFailure(&diagnostic, err);`
pub fn invocationFailure(diagnostic: *data.Diagnostic, reason: anyerror) data.LuaInvocation {
    if (diagnostic.len == 0) {
        diagnostic.set(
            "Lua action failed: {s}",
            .{
                @errorName(reason),
            },
        );
    }

    return .{
        .failed = .{
            .reason = reason,
            .diagnostic = diagnostic.*,
        },
    };
}

/// Checks all plugin references and rejects recursive Lua effects before any effect runs.
/// Example: `const validation = lua_actions.validateBatch(registry, &batch, &diagnostic);`
pub fn validateBatch(registry: ?*Registry, batch: *const data.EffectBatch, diagnostic: *data.Diagnostic) data.LuaValidation {
    for (batch.slice()) |effect| {
        switch (effect) {
            .plugin => |requested| {
                const active_registry = registry orelse {
                    diagnostic.set(
                        "Lua callback referenced a plugin but no registry is active",
                        .{},
                    );
                    return validationFailure(diagnostic, error.PluginRegistryUnavailable);
                };
                _ = active_registry.resolve(requested) catch |err| {
                    diagnostic.set(
                        "Lua callback returned an invalid plugin action: {s}",
                        .{@errorName(err)},
                    );
                    return validationFailure(diagnostic, err);
                };
            },
            .lua_callback, .lua_expr => {
                diagnostic.set(
                    "Lua callback returned a recursive Lua action",
                    .{},
                );
                return validationFailure(diagnostic, error.InvalidCallbackResult);
            },
            else => {},
        }
    }

    return .valid;
}
fn validationFailure(diagnostic: *data.Diagnostic, reason: anyerror) data.LuaValidation {
    return .{ .failed = .{
        .reason = reason,
        .diagnostic = diagnostic.*,
    } };
}
