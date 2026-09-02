//! Compiler for declarative plugin specifications.

const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, snapshot: *config_model.Snapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.plugins must be an array", .{});
        return error.InvalidConfig;
    }

    const count = lua.lua_rawlen(state, absolute);
    if (count > config_model.max_plugins) {
        diagnostic.set("config.plugins exceeds {d} entries", .{config_model.max_plugins});
        return error.InvalidConfig;
    }

    snapshot.plugin_count = 0;
    for (0..count) |plugin_index| {
        _ = lua.lua_geti(state, absolute, @intCast(plugin_index + 1));
        defer value.pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("plugin {d} must be a telar.plugin value", .{plugin_index + 1});
            return error.InvalidConfig;
        }

        const plugin_table = lua.lua_absindex(state, -1);
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

        var spec: config_model.PluginSpec = .{ .path_len = @intCast(path.len) };
        @memcpy(spec.path_bytes[0..path.len], path);
        _ = lua.lua_getfield(state, plugin_table, "enabled");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                value.pop(state, 1);
                diagnostic.set("plugin {d}.enabled must be a boolean", .{plugin_index + 1});
                return error.InvalidConfig;
            }

            spec.enabled = lua.lua_toboolean(state, -1) != 0;
        }
        value.pop(state, 1);
        snapshot.plugins[plugin_index] = spec;
    }
    snapshot.plugin_count = @intCast(count);
}
