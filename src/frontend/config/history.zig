//! Compiler for bounded runtime history configuration.

const lua_api = @import("lua-api");
const RuntimeSnapshotType = @import("RuntimeSnapshot.zig");
const DiagnosticType = @import("telar-client").Diagnostic;
const value = @import("lua_value.zig");
const HistoryParser = @import("HistoryParser.zig");

pub fn parse(state: *lua_api.c.lua_State, runtime: *RuntimeSnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime.history must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "path", "secrets_filter", "command_filters", "cwd_filters", "output" },
        .path = "config.runtime.history",
    }, diagnostic);

    var parser: HistoryParser = .{ .state = state, .runtime = runtime, .diagnostic = diagnostic };
    try parser.parseOutput(absolute);
    try parser.parsePath(absolute);
    try parser.parseSecretsFilter(absolute);
    try parser.parsePatterns(absolute, .commands);
    try parser.parsePatterns(absolute, .cwds);
}

pub const PatternKind = enum {
    commands,
    cwds,
};
