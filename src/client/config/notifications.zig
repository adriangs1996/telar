//! Compiler for client notification delivery.

const data = @import("model");
const lua_api = @import("lua-api");
const Snapshot = @import("Snapshot.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua_api.c.lua_State, snapshot: *Snapshot, diagnostic: *data.Diagnostic) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.notifications must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{"delivery"},
        .path = "config.client.notifications",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "delivery");
    defer value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const delivery = value.string(state, -1) orelse {
        diagnostic.set("config.client.notifications.delivery must be a string", .{});
        return error.InvalidConfig;
    };
    snapshot.notification_delivery = data.NotificationDelivery.parse(delivery) orelse {
        diagnostic.set("config.client.notifications.delivery must be telar, terminal or system", .{});
        return error.InvalidConfig;
    };
}
