//! Compiler for client notification delivery.

const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, snapshot: *config_model.Snapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.notifications must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{"delivery"},
        .path = "config.client.notifications",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "delivery");
    defer value.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return;
    }

    const delivery = value.string(state, -1) orelse {
        diagnostic.set("config.client.notifications.delivery must be a string", .{});
        return error.InvalidConfig;
    };
    snapshot.notification_delivery = config_model.NotificationDelivery.parse(delivery) orelse {
        diagnostic.set("config.client.notifications.delivery must be telar, terminal or system", .{});
        return error.InvalidConfig;
    };
}
