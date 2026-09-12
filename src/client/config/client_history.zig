//! Compiler for client history presentation and activation behavior.

const lua_api = @import("lua-api");
const SnapshotType = @import("Snapshot.zig");
const DiagnosticType = @import("Diagnostic.zig");
const value = @import("lua_value.zig");
const ClientHistoryParser = @import("ClientHistoryParser.zig");

pub fn parse(state: *lua_api.c.lua_State, snapshot: *SnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.history must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "show_agent_commands", "enter", "match" },
        .path = "config.client.history",
    }, diagnostic);
    var parser: ClientHistoryParser = .{ .state = state, .snapshot = snapshot, .diagnostic = diagnostic };
    try parser.parseMatch(absolute);
    try parser.parseVisibility(absolute);
    try parser.parseEnter(absolute);
}
