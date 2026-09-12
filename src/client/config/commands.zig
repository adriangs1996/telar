//! Compiler for bounded runtime helper commands.

const lua_api = @import("lua-api");
const RuntimeSnapshotType = @import("RuntimeSnapshot.zig");
const DiagnosticType = @import("Diagnostic.zig");
const value = @import("lua_value.zig");
const config_model = @import("model.zig");
const CommandInput = @import("CommandInput.zig");
const CommandSpecType = @import("CommandSpec.zig");
const std = @import("std");
const IntegerInput = @import("IntegerInput.zig");

pub fn parseAgentDescriptions(state: *lua_api.c.lua_State, runtime: *RuntimeSnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime.agent_descriptions must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "command", "timeout_ms" },
        .path = "config.runtime.agent_descriptions",
    }, diagnostic);
    runtime.agent_descriptions = try parseCommand(state, .{
        .table = absolute,
        .label = "config.runtime.agent_descriptions",
        .command_path = "config.runtime.agent_descriptions.command",
    }, diagnostic);
}

pub fn parseEngine(state: *lua_api.c.lua_State, runtime: *RuntimeSnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime.engine must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "command", "timeout_ms", "idle_timeout_ms" },
        .path = "config.runtime.engine",
    }, diagnostic);
    runtime.engine = try parseCommand(state, .{
        .table = absolute,
        .label = "config.runtime.engine",
        .command_path = "config.runtime.engine.command",
    }, diagnostic);
    runtime.engine_idle_timeout_ms = try parseBoundedInteger(state, .{
        .table = absolute,
        .field = "idle_timeout_ms",
        .label = "config.runtime.engine",
        .bounds = .{
            .default = config_model.default_engine_idle_timeout_ms,
            .min = config_model.min_engine_idle_timeout_ms,
            .max = config_model.max_engine_idle_timeout_ms,
        },
    }, diagnostic);
}

fn parseCommand(state: *lua_api.c.lua_State, input: CommandInput, diagnostic: *DiagnosticType) !CommandSpecType {
    _ = lua_api.c.lua_getfield(state, input.table, "command");
    defer value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("{s}.command must be an array", .{input.label});
        return error.InvalidConfig;
    }

    const command_table = lua_api.c.lua_absindex(state, -1);
    const count = lua_api.c.lua_rawlen(state, command_table);
    if (count == 0 or count > config_model.max_agent_description_command_args) {
        diagnostic.set("{s}.command must contain 1..{d} arguments", .{ input.label, config_model.max_agent_description_command_args });
        return error.InvalidConfig;
    }
    try value.ensureArrayOnly(state, .{
        .index = command_table,
        .count = count,
        .path = input.command_path,
    }, diagnostic);

    var command: CommandSpecType = .{};
    for (0..count) |argument_index| {
        _ = lua_api.c.lua_geti(state, command_table, @intCast(argument_index + 1));
        defer value.pop(state, 1);
        const argument = value.string(state, -1) orelse {
            diagnostic.set("{s}.command[{d}] must be a string", .{ input.label, argument_index + 1 });
            return error.InvalidConfig;
        };
        if ((argument_index == 0 and argument.len == 0) or
            argument.len > std.math.maxInt(u16) or
            argument.len > config_model.max_agent_description_command_bytes - command.byte_len or
            std.mem.indexOfScalar(u8, argument, 0) != null)
        {
            diagnostic.set("{s}.command exceeds its {d}-byte limit", .{ input.label, config_model.max_agent_description_command_bytes });
            return error.InvalidConfig;
        }

        command.offsets[argument_index] = command.byte_len;
        command.lengths[argument_index] = @intCast(argument.len);
        @memcpy(command.bytes[command.byte_len..][0..argument.len], argument);
        command.byte_len += @intCast(argument.len);
    }
    command.argument_count = @intCast(count);
    command.timeout_ms = try parseBoundedInteger(state, .{
        .table = input.table,
        .field = "timeout_ms",
        .label = input.label,
        .bounds = .{
            .default = command.timeout_ms,
            .min = config_model.min_agent_description_timeout_ms,
            .max = config_model.max_agent_description_timeout_ms,
        },
    }, diagnostic);
    return command;
}

fn parseBoundedInteger(state: *lua_api.c.lua_State, input: IntegerInput, diagnostic: *DiagnosticType) !u32 {
    _ = lua_api.c.lua_getfield(state, input.table, input.field);
    defer value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return input.bounds.default;
    }

    const parsed = value.integer(state, -1) orelse {
        diagnostic.set("{s}.{s} must be an integer", .{ input.label, input.field });
        return error.InvalidConfig;
    };
    if (parsed < input.bounds.min or parsed > input.bounds.max) {
        diagnostic.set("{s}.{s} must be in {d}..{d}", .{ input.label, input.field, input.bounds.min, input.bounds.max });
        return error.InvalidConfig;
    }

    return @intCast(parsed);
}
