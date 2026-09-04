//! Sandboxed Lua host executed by the internal `tap-worker` subcommand.

const std = @import("std");
const core = @import("telar-core");
const lua_runtime = @import("telar-lua");
const lua = @import("lua-api").c;
const effects = @import("effects.zig");
const protocol = @import("protocol.zig");

const Io = std.Io;
const max_frame_bytes = 128 * 1024 * 1024;
const max_entry_bytes = 1024 * 1024;
const max_json_bytes = 1024 * 1024;

const Host = struct {
    io: Io,
    gpa: std.mem.Allocator,
    vm: *lua_runtime.Vm,
    package_root: []const u8,
    callback_ref: c_int = lua.LUA_NOREF,
    module_cache_ref: c_int = lua.LUA_NOREF,

    fn init(init_process: std.process.Init, entry_path: []const u8) !Host {
        return initWithResources(init_process.io, init_process.gpa, entry_path);
    }

    fn initWithResources(io: Io, gpa: std.mem.Allocator, entry_path: []const u8) !Host {
        const root = std.fs.path.dirname(entry_path) orelse return error.InvalidEntrypoint;
        var host: Host = .{
            .io = io,
            .gpa = gpa,
            .vm = try lua_runtime.Vm.init(io, .{
                .memory = 64 * 1024 * 1024,
                .instructions = 5_000_000,
                .deadline_after_ns = 200 * std.time.ns_per_ms,
            }),
            .package_root = try gpa.dupe(u8, root),
        };
        errdefer host.deinit();
        try lua_runtime.sandbox.open(host.vm.state);
        try host.installTelar();
        host.installRequire();
        try host.loadPlugin(entry_path);
        return host;
    }

    fn deinit(host: *Host) void {
        host.vm.deinit();
        host.gpa.free(host.package_root);
    }

    fn installTelar(host: *Host) !void {
        try host.vm.evaluate(@embedFile("bootstrap.lua"), "@telar-tap-bootstrap.lua");
        const state = host.vm.state;
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            return error.InvalidBootstrap;
        }
        lua.lua_pushvalue(state, -1);
        lua.lua_setglobal(state, "telar");

        _ = lua.lua_getfield(state, -1, "redact");
        lua.lua_pushlightuserdata(state, host);
        lua.lua_pushcclosure(state, redactSecrets, 1);
        lua.lua_setfield(state, -2, "secrets");
        pop(state, 1);

        _ = lua.lua_getfield(state, -1, "json");
        lua.lua_pushlightuserdata(state, host);
        lua.lua_pushcclosure(state, decodeJson, 1);
        lua.lua_setfield(state, -2, "decode");
        lua.lua_settop(state, 0);
    }

    fn installRequire(host: *Host) void {
        const state = host.vm.state;
        lua.lua_createtable(state, 0, 16);
        host.module_cache_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        lua.lua_pushlightuserdata(state, host);
        lua.lua_pushcclosure(state, requireLocal, 1);
        lua.lua_setglobal(state, "require");
    }

    fn loadPlugin(host: *Host, entry_path: []const u8) !void {
        const source = try Io.Dir.cwd().readFileAlloc(host.io, entry_path, host.gpa, .limited(max_entry_bytes));
        defer host.gpa.free(source);
        host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
        try host.vm.evaluate(source, "@tap-plugin.lua");
        const state = host.vm.state;
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            return error.InvalidTapPlugin;
        }
        _ = lua.lua_getfield(state, -1, "on_exchange");
        if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) {
            return error.MissingExchangeHandler;
        }
        host.callback_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        lua.lua_settop(state, 0);
    }

    fn invoke(host: *Host, exchange: protocol.Exchange) !effects.Batch {
        const state = host.vm.state;
        lua.lua_settop(state, 0);
        defer lua.lua_settop(state, 0);
        host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
        _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, host.callback_ref);
        pushExchange(state, exchange);
        if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
            return error.TapCallbackFailed;
        }
        return parseEffects(state, -1);
    }
};

/// Runs one long-lived worker until its framed stdin closes.
///
/// ```zig
/// try host.run(process_init, entry_path);
/// ```
pub fn run(init_process: std.process.Init, entry_path: []const u8) !void {
    var host = try Host.init(init_process, entry_path);
    defer host.deinit();
    var stdin_buffer: [16 * 1024]u8 = undefined;
    var input = Io.File.stdin().readerStreaming(init_process.io, &stdin_buffer);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(init_process.io, &stdout_buffer);

    while (true) {
        var prefix: [protocol.prefix_bytes]u8 = undefined;
        input.interface.readSliceAll(&prefix) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |other| return other,
        };
        const frame_len = std.mem.readInt(u32, &prefix, .little);
        if (frame_len == 0 or frame_len > max_frame_bytes) {
            return error.InvalidTapFrame;
        }
        const frame = try init_process.gpa.alloc(u8, frame_len);
        defer {
            std.crypto.secureZero(u8, frame);
            init_process.gpa.free(frame);
        }
        try input.interface.readSliceAll(frame);
        const exchange = try protocol.decodeExchange(frame);
        const encoded = try init_process.gpa.alloc(u8, effects.max_effect_bytes);
        defer {
            std.crypto.secureZero(u8, encoded);
            init_process.gpa.free(encoded);
        }
        const payload = if (host.invoke(exchange)) |batch|
            try protocol.encodeEffects(encoded, exchange.id, &batch)
        else |_|
            try protocol.encodeError(encoded, exchange.id, host.vm.errorMessage());
        std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
        try output.interface.writeAll(&prefix);
        try output.interface.writeAll(payload);
        try output.interface.flush();
    }
}

fn pushExchange(state: *lua.lua_State, exchange: protocol.Exchange) void {
    lua.lua_createtable(state, 0, 14);
    const destination = LuaTable.init(state, -1);
    destination.setInteger("id", exchange.id);
    destination.setInteger("pane", core.schema.id.raw(exchange.pane));
    destination.setInteger("pane_generation", exchange.pane_generation);
    destination.setString("host", exchange.host);
    destination.setString("protocol", @tagName(exchange.protocol));
    destination.setString("dialect", @tagName(exchange.dialect));
    destination.setInteger("connection_id", exchange.connection_id);
    destination.setInteger("stream_id", exchange.stream_id);
    destination.setString("method", exchange.method);
    destination.setString("target", exchange.target);
    destination.setInteger("status", if (exchange.response) |half| half.status_code else 0);
    destination.setString("outcome", @tagName(if (exchange.response) |half| half.outcome else exchange.request.?.outcome));
    destination.setInteger("started_at_ms", exchange.started_at_ms);
    destination.setInteger("finished_at_ms", if (exchange.response) |half| half.finished_at_ms else exchange.request.?.finished_at_ms);
    pushHalf(state, exchange.request);
    lua.lua_setfield(state, -2, "request");
    pushHalf(state, exchange.response);
    lua.lua_setfield(state, -2, "response");
    freezeTable(state);
}

fn pushHalf(state: *lua.lua_State, optional: ?protocol.Half) void {
    const half = optional orelse {
        lua.lua_pushnil(state);
        return;
    };
    lua.lua_createtable(state, 0, 6);
    const destination = LuaTable.init(state, -1);
    pushHead(state, half.head);
    lua.lua_setfield(state, -2, "head");
    destination.setString("body", half.body);
    destination.setBoolean("body_truncated", half.body_truncated);
    destination.setString("body_encoding", half.encoding);
    destination.setBoolean("body_decoded", half.decoded);
    freezeTable(state);
}

fn pushHead(state: *lua.lua_State, raw: []const u8) void {
    lua.lua_createtable(state, 0, 2);
    const destination = LuaTable.init(state, -1);
    destination.setString("raw", raw);
    lua.lua_createtable(state, 0, 0);
    var index: c_int = 1;
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const separator = if (line.len > 1 and line[0] == ':')
            std.mem.indexOfScalarPos(u8, line, 1, ':')
        else
            std.mem.indexOfScalar(u8, line, ':');
        const colon = separator orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        lua.lua_createtable(state, 0, 2);
        const field = LuaTable.init(state, -1);
        field.setString("name", name);
        field.setString("value", value);
        freezeTable(state);
        lua.lua_seti(state, -2, index);
        index += 1;
    }
    freezeTable(state);
    lua.lua_setfield(state, -2, "fields");
    freezeTable(state);
}

fn parseEffects(state: *lua.lua_State, index: c_int) !effects.Batch {
    if (lua.lua_type(state, index) == lua.LUA_TNIL) {
        return .{};
    }
    if (lua.lua_type(state, index) != lua.LUA_TTABLE) {
        return error.InvalidEffectBatch;
    }
    const absolute = lua.lua_absindex(state, index);
    const count = lua.lua_rawlen(state, absolute);
    if (count > effects.max_effects) {
        return error.TooManyEffects;
    }
    var batch: effects.Batch = .{ .len = @intCast(count) };

    for (0..count) |effect_index| {
        _ = lua.lua_geti(state, absolute, @intCast(effect_index + 1));
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            return error.InvalidEffect;
        }
        const effect_table = lua.lua_absindex(state, -1);
        const effect = LuaTable.init(state, effect_table);
        const kind = try effect.string("__telar_kind", true);
        batch.items[effect_index] = if (std.mem.eql(u8, kind, "record_command"))
            .{ .record_command = .{
                .command = try effect.string("command", true),
                .cwd = try effect.string("cwd", false),
                .provider = try effect.string("provider", false),
                .tool_call_id = try effect.string("tool_call_id", false),
                .session = try effect.optionalString("session"),
                .exit_code = @intCast(try effect.integer("exit_code", 0)),
                .started_at_ms = try effect.integer("started_at_ms", 0),
                .duration_ms = @intCast(try effect.integer("duration_ms", 0)),
                .redact = try effect.boolean("redact", true),
            } }
        else if (std.mem.eql(u8, kind, "agent_evidence"))
            .{ .agent_evidence = .{
                .pane = core.schema.id.pane(@intCast(try effect.integer("pane", 0))) catch return error.InvalidEffect,
                .state = try agentState(try effect.string("state", true)),
                .confidence = try confidence(try effect.string("confidence", true)),
            } }
        else if (std.mem.eql(u8, kind, "notification"))
            .{ .notification = .{
                .level = try notificationLevel(try effect.string("level", false)),
                .duration_ms = @intCast(try effect.integer("duration_ms", core.schema.default_notification_duration_ms)),
                .title = try effect.string("title", true),
                .message = try effect.string("message", false),
            } }
        else
            return error.InvalidEffect;
    }
    return batch;
}

const LuaTable = struct {
    state: *lua.lua_State,
    index: c_int,

    fn init(state: *lua.lua_State, index: c_int) LuaTable {
        return .{ .state = state, .index = lua.lua_absindex(state, index) };
    }

    fn string(table: LuaTable, name: [*:0]const u8, required: bool) ![]const u8 {
        _ = lua.lua_getfield(table.state, table.index, name);
        defer pop(table.state, 1);
        if (!required and lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
            return "";
        }

        return luaString(table.state, -1) orelse error.InvalidEffect;
    }

    fn optionalString(table: LuaTable, name: [*:0]const u8) !?[]const u8 {
        _ = lua.lua_getfield(table.state, table.index, name);
        defer pop(table.state, 1);
        if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
            return null;
        }

        return luaString(table.state, -1) orelse error.InvalidEffect;
    }

    fn integer(table: LuaTable, name: [*:0]const u8, default: i64) !i64 {
        _ = lua.lua_getfield(table.state, table.index, name);
        defer pop(table.state, 1);
        if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
            return default;
        }

        var valid: c_int = 0;
        const value = lua.lua_tointegerx(table.state, -1, &valid);

        return if (valid != 0) value else error.InvalidEffect;
    }

    fn boolean(table: LuaTable, name: [*:0]const u8, default: bool) !bool {
        _ = lua.lua_getfield(table.state, table.index, name);
        defer pop(table.state, 1);
        if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
            return default;
        }

        if (lua.lua_type(table.state, -1) != lua.LUA_TBOOLEAN) {
            return error.InvalidEffect;
        }

        return lua.lua_toboolean(table.state, -1) != 0;
    }

    fn setString(table: LuaTable, name: [*:0]const u8, value: []const u8) void {
        _ = lua.lua_pushlstring(table.state, value.ptr, value.len);
        lua.lua_setfield(table.state, table.index, name);
    }

    fn setInteger(table: LuaTable, name: [*:0]const u8, value: anytype) void {
        lua.lua_pushinteger(table.state, @intCast(value));
        lua.lua_setfield(table.state, table.index, name);
    }

    fn setBoolean(table: LuaTable, name: [*:0]const u8, value: bool) void {
        lua.lua_pushboolean(table.state, @intFromBool(value));
        lua.lua_setfield(table.state, table.index, name);
    }
};

fn agentState(value: []const u8) !core.schema.AgentReportState {
    if (std.mem.eql(u8, value, "working")) {
        return .working;
    }
    if (std.mem.eql(u8, value, "ready")) {
        return .ready;
    }
    if (std.mem.eql(u8, value, "blocked")) {
        return .blocked;
    }
    return error.InvalidEffect;
}

fn confidence(value: []const u8) !effects.Confidence {
    if (std.mem.eql(u8, value, "low")) {
        return .low;
    }
    if (std.mem.eql(u8, value, "medium")) {
        return .medium;
    }
    return error.InvalidEffect;
}

fn notificationLevel(value: []const u8) !core.schema.NotificationLevel {
    if (value.len == 0 or std.mem.eql(u8, value, "info")) {
        return .info;
    }
    if (std.mem.eql(u8, value, "success")) {
        return .success;
    }
    if (std.mem.eql(u8, value, "warning")) {
        return .warning;
    }
    if (std.mem.eql(u8, value, "failure")) {
        return .failure;
    }
    return error.InvalidEffect;
}

fn requireLocal(state_optional: ?*lua.lua_State) callconv(.c) c_int {
    const state = state_optional.?;
    const host = hostFromUpvalue(state) orelse return raise(state, "missing require context");
    const name = luaString(state, 1) orelse return raise(state, "require expects a module name");
    if (std.mem.eql(u8, name, "telar")) {
        _ = lua.lua_getglobal(state, "telar");
        return 1;
    }
    if (!validModuleName(name)) {
        return raise(state, "invalid local module name");
    }

    _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, host.module_cache_ref);
    _ = lua.lua_pushlstring(state, name.ptr, name.len);
    _ = lua.lua_rawget(state, -2);
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        lua.lua_remove(state, -2);
        return 1;
    }
    pop(state, 1);

    var relative: [std.fs.max_path_bytes]u8 = undefined;
    var cursor: usize = 0;
    for (name) |byte| {
        if (cursor == relative.len) {
            return raise(state, "module path too long");
        }
        relative[cursor] = if (byte == '.') std.fs.path.sep else byte;
        cursor += 1;
    }
    if (relative.len - cursor < 4) {
        return raise(state, "module path too long");
    }
    @memcpy(relative[cursor..][0..4], ".lua");
    cursor += 4;
    var candidate: [std.fs.max_path_bytes]u8 = undefined;
    const joined = std.fmt.bufPrint(&candidate, "{s}/{s}", .{ host.package_root, relative[0..cursor] }) catch return raise(state, "module path too long");
    var resolved_storage: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = Io.Dir.cwd().realPathFile(host.io, joined, &resolved_storage) catch return raise(state, "cannot resolve local module");
    const resolved = resolved_storage[0..resolved_len];
    if (!pathInside(host.package_root, resolved) or resolved_len == resolved_storage.len) {
        return raise(state, "module escapes package");
    }
    resolved_storage[resolved_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(resolved_storage[0..resolved_len :0]);
    if (lua.luaL_loadfilex(state, path_z, "t") != lua.LUA_OK) {
        return lua.lua_error(state);
    }
    if (lua.lua_pcallk(state, 0, 1, 0, 0, null) != lua.LUA_OK) {
        return lua.lua_error(state);
    }
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        pop(state, 1);
        lua.lua_pushboolean(state, 1);
    }
    _ = lua.lua_pushlstring(state, name.ptr, name.len);
    lua.lua_pushvalue(state, -2);
    lua.lua_rawset(state, -4);
    lua.lua_remove(state, -2);
    return 1;
}

fn redactSecrets(state_optional: ?*lua.lua_State) callconv(.c) c_int {
    const state = state_optional.?;
    const input = luaString(state, 1) orelse return raise(state, "redact.secrets expects a string");
    const output = if (core.history_filter.looksLikeSecret(input)) "[REDACTED]" else input;
    _ = lua.lua_pushlstring(state, output.ptr, output.len);
    return 1;
}

fn decodeJson(state_optional: ?*lua.lua_State) callconv(.c) c_int {
    const state = state_optional.?;
    const input = luaString(state, 1) orelse return raise(state, "json.decode expects a string");
    if (input.len > max_json_bytes) {
        return raise(state, "JSON input is too large");
    }
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, input, .{ .max_value_len = max_json_bytes }) catch return raise(state, "invalid JSON");
    defer parsed.deinit();
    pushJson(state, parsed.value, 0) catch return raise(state, "JSON exceeds depth limit");
    return 1;
}

fn pushJson(state: *lua.lua_State, value: std.json.Value, depth: u8) !void {
    if (depth == 64) {
        return error.JsonDepth;
    }
    switch (value) {
        .null => lua.lua_pushnil(state),
        .bool => |boolean| lua.lua_pushboolean(state, @intFromBool(boolean)),
        .integer => |integer| lua.lua_pushinteger(state, integer),
        .float => |float| lua.lua_pushnumber(state, float),
        .number_string => |number| {
            const parsed = std.fmt.parseFloat(f64, number) catch return error.InvalidJson;
            lua.lua_pushnumber(state, parsed);
        },
        .string => |string| _ = lua.lua_pushlstring(state, string.ptr, string.len),
        .array => |array| {
            lua.lua_createtable(state, @intCast(array.items.len), 0);
            for (array.items, 1..) |item, index| {
                try pushJson(state, item, depth + 1);
                lua.lua_seti(state, -2, @intCast(index));
            }
        },
        .object => |object| {
            lua.lua_createtable(state, 0, @intCast(object.count()));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                _ = lua.lua_pushlstring(state, entry.key_ptr.ptr, entry.key_ptr.len);
                try pushJson(state, entry.value_ptr.*, depth + 1);
                lua.lua_settable(state, -3);
            }
        },
    }
}

fn freezeTable(state: *lua.lua_State) void {
    lua.lua_createtable(state, 0, 0);
    lua.lua_createtable(state, 0, 3);
    lua.lua_pushvalue(state, -3);
    lua.lua_setfield(state, -2, "__index");
    lua.lua_pushcclosure(state, readonlyNewIndex, 0);
    lua.lua_setfield(state, -2, "__newindex");
    lua.lua_pushboolean(state, 0);
    lua.lua_setfield(state, -2, "__metatable");
    _ = lua.lua_setmetatable(state, -2);
    lua.lua_remove(state, -2);
}

fn readonlyNewIndex(state_optional: ?*lua.lua_State) callconv(.c) c_int {
    return raise(state_optional.?, "exchange is immutable");
}

fn luaString(state: *lua.lua_State, index: c_int) ?[]const u8 {
    var len: usize = 0;
    const value = lua.lua_tolstring(state, index, &len) orelse return null;
    return value[0..len];
}

fn hostFromUpvalue(state: *lua.lua_State) ?*Host {
    const pointer = lua.lua_touserdata(state, lua.lua_upvalueindex(1)) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn raise(state: *lua.lua_State, message: [*:0]const u8) c_int {
    _ = lua.lua_pushstring(state, message);
    return lua.lua_error(state);
}

fn pop(state: *lua.lua_State, count: c_int) void {
    lua.lua_settop(state, -count - 1);
}

fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') {
        return false;
    }
    var previous_dot = false;
    for (name) |byte| {
        if (byte == '.') {
            if (previous_dot) {
                return false;
            }
            previous_dot = true;
        } else {
            previous_dot = false;
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
                return false;
            }
        }
    }
    return true;
}

fn pathInside(root: []const u8, candidate: []const u8) bool {
    return std.mem.startsWith(u8, candidate, root) and
        (candidate.len == root.len or (candidate.len > root.len and candidate[root.len] == std.fs.path.sep));
}

test "shipped agent command tap accumulates Anthropic and OpenAI arguments" {
    var host = try Host.initWithResources(std.testing.io, std.testing.allocator, "examples/plugins/agent-commands/plugin.lua");
    defer host.deinit();

    const anthropic_body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"zig \"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"build test\\\"}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n";
    const anthropic = try host.invoke(testExchange(.anthropic_messages, anthropic_body));
    try std.testing.expectEqual(@as(u8, 2), anthropic.len);
    try std.testing.expectEqualStrings("zig build test", anthropic.items[0].record_command.command);
    try std.testing.expectEqualStrings("toolu_1", anthropic.items[0].record_command.tool_call_id);
    try std.testing.expectEqualStrings("claude", anthropic.items[0].record_command.provider);

    const openai_body =
        "event: response.output_item.added\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_1\",\"call_id\":\"call_1\",\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"\"}}\n\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"{\\\"cmd\\\":\\\"rg \"}\n\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"TODO\\\"}\"}\n\n" ++
        "event: response.function_call_arguments.done\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"name\":\"exec_command\"}\n\n";
    const openai = try host.invoke(testExchange(.openai_responses, openai_body));
    try std.testing.expectEqual(@as(u8, 2), openai.len);
    try std.testing.expectEqualStrings("rg TODO", openai.items[0].record_command.command);
    try std.testing.expectEqualStrings("call_1", openai.items[0].record_command.tool_call_id);
    try std.testing.expectEqualStrings("codex", openai.items[0].record_command.provider);
}

test "shipped agent command tap maps non-stream shell commands and rejects unusable bodies" {
    var host = try Host.initWithResources(std.testing.io, std.testing.allocator, "examples/plugins/agent-commands/plugin.lua");
    defer host.deinit();

    const body =
        "{\"output\":[{\"id\":\"fc_2\",\"call_id\":\"call_2\",\"type\":\"function_call\"," ++
        "\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"git status\\\"}\"}]}";
    const complete = try host.invoke(testExchange(.openai_responses, body));
    try std.testing.expectEqual(@as(u8, 2), complete.len);
    try std.testing.expectEqualStrings("git status", complete.items[0].record_command.command);

    var truncated_exchange = testExchange(.openai_responses, body);
    truncated_exchange.response.?.body_truncated = true;
    const truncated = try host.invoke(truncated_exchange);
    try std.testing.expectEqual(@as(u8, 0), truncated.len);

    var undecoded_exchange = testExchange(.openai_responses, body);
    undecoded_exchange.response.?.decoded = false;
    const undecoded = try host.invoke(undecoded_exchange);
    try std.testing.expectEqual(@as(u8, 0), undecoded.len);
}

fn testExchange(dialect: @import("../proxy/root.zig").ApiDialect, body: []const u8) protocol.Exchange {
    return .{
        .id = 1,
        .generation = 1,
        .pane = @enumFromInt(1),
        .pane_generation = 1,
        .host = "api.example.com",
        .protocol = .h2,
        .dialect = dialect,
        .connection_id = 1,
        .stream_id = 1,
        .method = "POST",
        .target = "/v1/responses",
        .started_at_ms = 100,
        .request = null,
        .response = .{
            .head = ":status: 200\r\n",
            .body = body,
            .encoding = "identity",
            .decoded = true,
            .head_truncated = false,
            .body_truncated = false,
            .status_code = 200,
            .outcome = .finished,
            .finished_at_ms = 120,
        },
    };
}
