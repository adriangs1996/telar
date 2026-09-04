//! Compiler for runtime agent manifests.
//!
//! One `config.runtime.agents[]` entry names an agent and carries three kinds
//! of data: how to recognize it (`process_names`, `process_paths` and the
//! screen phrase lists), how to present it (`display_name`, `placeholder`,
//! `icon`) and which client capability it supports (`attachments`). Every
//! field except `name` is optional; a built-in name extends or overrides the
//! shipped manifest instead of creating a new agent.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

const Manifest = core.agent_manifest.Manifest;

const phrase_fields = .{ "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt" };
const text_fields = .{ "display_name", "placeholder", "icon" };

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
            .allowed = &(.{"name"} ++ phrase_fields ++ text_fields ++ .{ "attachments", "command_tools" }),
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

        inline for (phrase_fields) |field| {
            try parseList(state, .{
                .entry = entry,
                .field = field,
                .list = &@field(manifest, field),
                .position = position,
            }, diagnostic);
        }

        const input: EntryInput = .{ .entry = entry, .manifest = manifest, .position = position };
        try parseCommandTools(state, input, diagnostic);
        try parsePresentation(state, input, diagnostic);
    }
}

fn parseCommandTools(state: *lua.lua_State, input: EntryInput, diagnostic: *config_model.Diagnostic) !void {
    _ = lua.lua_getfield(state, input.entry, "command_tools");
    defer value.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.agents[{d}].command_tools must be an array", .{input.position});
        return error.InvalidConfig;
    }

    const tools = lua.lua_absindex(state, -1);
    const count = lua.lua_rawlen(state, tools);
    try value.ensureArrayOnly(state, .{ .index = tools, .count = count, .path = "config.runtime.agents[].command_tools" }, diagnostic);
    for (1..count + 1) |tool_position| {
        _ = lua.lua_rawgeti(state, tools, @intCast(tool_position));
        defer value.pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.agents[{d}].command_tools[{d}] must be a table", .{ input.position, tool_position });
            return error.InvalidConfig;
        }

        const mapping = lua.lua_absindex(state, -1);
        try value.ensureOnlyFields(state, .{ .index = mapping, .allowed = &.{ "tool", "field" }, .path = "config.runtime.agents[].command_tools[]" }, diagnostic);
        _ = lua.lua_getfield(state, mapping, "tool");
        const tool = value.string(state, -1) orelse "";
        _ = lua.lua_getfield(state, mapping, "field");
        const field = value.string(state, -1) orelse "";
        input.manifest.command_tools.append(tool, field) catch |err| {
            value.pop(state, 2);
            diagnostic.set("config.runtime.agents[{d}].command_tools[{d}] {s}", .{ input.position, tool_position, switch (err) {
                error.EmptyEntry => "requires non-empty tool and field strings",
                error.EntryTooLong => "contains an oversized tool or field",
                error.TooManyEntries => "exceeds the command tool limit",
            } });
            return error.InvalidConfig;
        };
        value.pop(state, 2);
    }
}

const EntryInput = struct {
    entry: c_int,
    manifest: *Manifest,
    position: usize,
};

const FieldLookup = struct {
    entry: c_int,
    position: usize,
    field: [:0]const u8,
};

const TextValue = struct {
    field: []const u8,
    text: []const u8,
};

/// Reads the optional display fields and the attachment policy of one entry.
fn parsePresentation(state: *lua.lua_State, input: EntryInput, diagnostic: *config_model.Diagnostic) !void {
    inline for (text_fields) |field| {
        const lookup: FieldLookup = .{ .entry = input.entry, .position = input.position, .field = field };
        if (try optionalText(state, lookup, diagnostic)) |text| {
            try applyText(input, .{ .field = field, .text = text }, diagnostic);
        }
    }

    const lookup: FieldLookup = .{ .entry = input.entry, .position = input.position, .field = "attachments" };
    if (try optionalText(state, lookup, diagnostic)) |text| {
        input.manifest.attachments = attachmentMarkers(text) orelse {
            diagnostic.set("config.runtime.agents[{d}].attachments must be \"none\", \"ordered\", \"stable_number\" or \"pasted_path\"", .{input.position});
            return error.InvalidConfig;
        };
    }
}

fn attachmentMarkers(text: []const u8) ?core.agent_manifest.AttachmentMarkers {
    inline for (std.meta.fields(core.agent_manifest.AttachmentMarkers)) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

/// Returns a printable string field, `null` when absent, and a diagnostic
/// when present with the wrong shape. The slice borrows the Lua stack value,
/// which stays alive while the entry table is on the stack.
fn optionalText(state: *lua.lua_State, lookup: FieldLookup, diagnostic: *config_model.Diagnostic) !?[]const u8 {
    _ = lua.lua_getfield(state, lookup.entry, lookup.field.ptr);
    defer value.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return null;
    }

    const text = value.string(state, -1) orelse "";
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or hasControlBytes(text)) {
        diagnostic.set("config.runtime.agents[{d}].{s} must be a printable string", .{ lookup.position, lookup.field });
        return error.InvalidConfig;
    }

    return text;
}

/// Stores one presentation string on the manifest. `icon` must also occupy
/// exactly one cell so custom marks align with the built-in artwork.
fn applyText(input: EntryInput, item: TextValue, diagnostic: *config_model.Diagnostic) !void {
    if (std.mem.eql(u8, item.field, "icon") and core.ui.measure(item.text) != 1) {
        diagnostic.set("config.runtime.agents[{d}].icon must be exactly one cell wide", .{input.position});
        return error.InvalidConfig;
    }

    const result = if (std.mem.eql(u8, item.field, "display_name"))
        input.manifest.setDisplayName(item.text)
    else if (std.mem.eql(u8, item.field, "placeholder"))
        input.manifest.setPlaceholder(item.text)
    else
        input.manifest.setIcon(item.text);

    result catch |err| {
        diagnostic.set("config.runtime.agents[{d}].{s} {s}", .{ input.position, item.field, switch (err) {
            error.TextTooLong => "is too long",
            error.EmptyText => "is empty",
        } });
        return error.InvalidConfig;
    };
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
