//! Compiler for runtime agent manifests.

const std = @import("std");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, runtime: *config_model.RuntimeSnapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.agents must be an array", .{});
        return error.InvalidConfig;
    }

    const count = lua.lua_rawlen(state, absolute);
    try value.ensureArrayOnly(state, .{ .index = absolute, .count = count, .path = "config.runtime.agents" }, diagnostic);
    for (1..count + 1) |position| {
        _ = lua.lua_rawgeti(state, absolute, @intCast(position));
        defer value.pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.agents[{d}] must be a table", .{position});
            return error.InvalidConfig;
        }

        const entry = lua.lua_absindex(state, -1);
        try value.ensureOnlyFields(state, .{
            .index = entry,
            .allowed = &.{ "name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt" },
            .path = "config.runtime.agents[]",
        }, diagnostic);
        _ = lua.lua_getfield(state, entry, "name");
        const name = value.string(state, -1) orelse "";
        const manifest = runtime.agent_manifests.add(name) catch |err| {
            value.pop(state, 1);
            diagnostic.set("config.runtime.agents[{d}].name {s}", .{ position, switch (err) {
                error.InvalidName => "must be lowercase letters, digits, '-', '_' or '.' (1..32 bytes)",
                error.DuplicateName => "is already defined",
                error.TooManyAgents => "exceeds the agent limit",
            } });
            return error.InvalidConfig;
        };
        value.pop(state, 1);

        inline for (.{ "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt" }) |field| {
            try parseList(state, .{
                .entry = entry,
                .field = field,
                .list = &@field(manifest, field),
                .position = position,
            }, diagnostic);
        }
    }
}

fn parseList(state: *lua.lua_State, input: anytype, diagnostic: *config_model.Diagnostic) !void {
    _ = lua.lua_getfield(state, input.entry, input.field.ptr);
    defer value.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.agents[{d}].{s} must be an array of strings", .{ input.position, input.field });
        return error.InvalidConfig;
    }

    const table = lua.lua_absindex(state, -1);
    const count = lua.lua_rawlen(state, table);
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "config.runtime.agents[].{s}", .{input.field}) catch unreachable;
    try value.ensureArrayOnly(state, .{ .index = table, .count = count, .path = path }, diagnostic);
    for (1..count + 1) |item| {
        _ = lua.lua_rawgeti(state, table, @intCast(item));
        defer value.pop(state, 1);
        const phrase = value.string(state, -1) orelse "";
        if (phrase.len == 0 or !std.unicode.utf8ValidateSlice(phrase) or hasControlBytes(phrase)) {
            diagnostic.set("config.runtime.agents[{d}].{s}[{d}] must be a printable string", .{ input.position, input.field, item });
            return error.InvalidConfig;
        }

        input.list.append(phrase) catch |err| {
            diagnostic.set("config.runtime.agents[{d}].{s}[{d}] {s}", .{ input.position, input.field, item, switch (err) {
                error.EntryTooLong => "is too long",
                error.TooManyEntries => "exceeds the list limit",
                error.EmptyEntry => "is empty",
            } });
            return error.InvalidConfig;
        };
    }
}

fn hasControlBytes(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return true;
        }
    }

    return false;
}
