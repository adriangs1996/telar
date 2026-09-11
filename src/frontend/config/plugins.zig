//! Compiler for declarative plugin specifications.

const lua_api = @import("lua-api");
const SnapshotType = @import("Snapshot.zig");
const DiagnosticType = @import("telar-client").Diagnostic;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");
const PluginSpecType = @import("PluginSpec.zig");

pub fn parse(state: *lua_api.c.lua_State, snapshot: *SnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.plugins must be an array", .{});
        return error.InvalidConfig;
    }

    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > config_model.max_plugins) {
        diagnostic.set("config.plugins exceeds {d} entries", .{config_model.max_plugins});
        return error.InvalidConfig;
    }

    snapshot.plugin_count = 0;
    for (0..count) |plugin_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(plugin_index + 1));
        defer value.pop(state, 1);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
            diagnostic.set("plugin {d} must be a telar.plugin value", .{plugin_index + 1});
            return error.InvalidConfig;
        }

        const plugin_table = lua_api.c.lua_absindex(state, -1);
        try value.ensureOnlyFields(state, .{
            .index = plugin_table,
            .allowed = &.{ "path", "enabled" },
            .path = "plugin",
        }, diagnostic);
        const path = try value.requiredStringField(state, .{ .index = plugin_table, .name = "path" }, diagnostic);
        if (path.len == 0 or path.len > config_model.max_plugin_path_bytes) {
            diagnostic.set("plugin {d} path is invalid", .{plugin_index + 1});
            return error.InvalidConfig;
        }

        var spec: PluginSpecType = .{ .path_len = @intCast(path.len) };
        @memcpy(spec.path_bytes[0..path.len], path);
        _ = lua_api.c.lua_getfield(state, plugin_table, "enabled");
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
                value.pop(state, 1);
                diagnostic.set("plugin {d}.enabled must be a boolean", .{plugin_index + 1});
                return error.InvalidConfig;
            }

            spec.enabled = lua_api.c.lua_toboolean(state, -1) != 0;
        }
        value.pop(state, 1);
        snapshot.plugins[plugin_index] = spec;
    }
    snapshot.plugin_count = @intCast(count);
}
