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
        const root = std.fs.path.dirname(entry_path) orelse return error.InvalidEntrypoint;
        var host: Host = .{
            .io = init_process.io,
            .gpa = init_process.gpa,
            .vm = try lua_runtime.Vm.init(init_process.io, .{
                .memory = 64 * 1024 * 1024,
                .instructions = 5_000_000,
                .deadline_after_ns = 200 * std.time.ns_per_ms,
            }),
            .package_root = try init_process.gpa.dupe(u8, root),
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
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidBootstrap;
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
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidTapPlugin;
        _ = lua.lua_getfield(state, -1, "on_exchange");
        if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) return error.MissingExchangeHandler;
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
        if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) return error.TapCallbackFailed;
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
        if (frame_len == 0 or frame_len > max_frame_bytes) return error.InvalidTapFrame;
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
    setInteger(state, -1, "id", exchange.id);
    setInteger(state, -1, "pane", core.schema.id.raw(exchange.pane));
    setInteger(state, -1, "pane_generation", exchange.pane_generation);
    setString(state, -1, "host", exchange.host);
    setString(state, -1, "protocol", @tagName(exchange.protocol));
    setString(state, -1, "dialect", @tagName(exchange.dialect));
    setInteger(state, -1, "connection_id", exchange.connection_id);
    setInteger(state, -1, "stream_id", exchange.stream_id);
    setString(state, -1, "method", exchange.method);
    setString(state, -1, "target", exchange.target);
    setInteger(state, -1, "status", if (exchange.response) |half| half.status_code else 0);
    setString(state, -1, "outcome", @tagName(if (exchange.response) |half| half.outcome else exchange.request.?.outcome));
    setInteger(state, -1, "started_at_ms", exchange.started_at_ms);
    setInteger(state, -1, "finished_at_ms", if (exchange.response) |half| half.finished_at_ms else exchange.request.?.finished_at_ms);
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
    pushHead(state, half.head);
    lua.lua_setfield(state, -2, "head");
    setString(state, -1, "body", half.body);
    setBoolean(state, -1, "body_truncated", half.body_truncated);
    setString(state, -1, "body_encoding", half.encoding);
    setBoolean(state, -1, "body_decoded", half.decoded);
    freezeTable(state);
}

fn pushHead(state: *lua.lua_State, raw: []const u8) void {
    lua.lua_createtable(state, 0, 2);
    setString(state, -1, "raw", raw);
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
        setString(state, -1, "name", name);
        setString(state, -1, "value", value);
        freezeTable(state);
        lua.lua_seti(state, -2, index);
        index += 1;
    }
    freezeTable(state);
    lua.lua_setfield(state, -2, "fields");
    freezeTable(state);
}

fn parseEffects(state: *lua.lua_State, index: c_int) !effects.Batch {
    if (lua.lua_type(state, index) == lua.LUA_TNIL) return .{};
    if (lua.lua_type(state, index) != lua.LUA_TTABLE) return error.InvalidEffectBatch;
    const absolute = lua.lua_absindex(state, index);
    const count = lua.lua_rawlen(state, absolute);
    if (count > effects.max_effects) return error.TooManyEffects;
    var batch: effects.Batch = .{ .len = @intCast(count) };

    for (0..count) |effect_index| {
        _ = lua.lua_geti(state, absolute, @intCast(effect_index + 1));
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidEffect;
        const effect_table = lua.lua_absindex(state, -1);
        const kind = try stringField(state, effect_table, "__telar_kind", true);
        batch.items[effect_index] = if (std.mem.eql(u8, kind, "record_command"))
            .{ .record_command = .{
                .command = try stringField(state, effect_table, "command", true),
                .cwd = try stringField(state, effect_table, "cwd", false),
                .provider = try stringField(state, effect_table, "provider", false),
                .session = try optionalStringField(state, effect_table, "session"),
                .exit_code = @intCast(try integerField(state, effect_table, "exit_code", 0)),
                .started_at_ms = try integerField(state, effect_table, "started_at_ms", 0),
                .duration_ms = @intCast(try integerField(state, effect_table, "duration_ms", 0)),
                .redact = try booleanField(state, effect_table, "redact", true),
            } }
        else if (std.mem.eql(u8, kind, "agent_evidence"))
            .{ .agent_evidence = .{
                .pane = core.schema.id.pane(@intCast(try integerField(state, effect_table, "pane", 0))) catch return error.InvalidEffect,
                .state = try agentState(try stringField(state, effect_table, "state", true)),
                .confidence = try confidence(try stringField(state, effect_table, "confidence", true)),
            } }
        else if (std.mem.eql(u8, kind, "notification"))
            .{ .notification = .{
                .level = try notificationLevel(try stringField(state, effect_table, "level", false)),
                .duration_ms = @intCast(try integerField(state, effect_table, "duration_ms", core.schema.default_notification_duration_ms)),
                .title = try stringField(state, effect_table, "title", true),
                .message = try stringField(state, effect_table, "message", false),
            } }
        else
            return error.InvalidEffect;
    }
    return batch;
}

fn stringField(state: *lua.lua_State, table: c_int, name: [*:0]const u8, required: bool) ![]const u8 {
    _ = lua.lua_getfield(state, table, name);
    defer pop(state, 1);
    if (!required and lua.lua_type(state, -1) == lua.LUA_TNIL) return "";
    return luaString(state, -1) orelse error.InvalidEffect;
}

fn optionalStringField(state: *lua.lua_State, table: c_int, name: [*:0]const u8) !?[]const u8 {
    _ = lua.lua_getfield(state, table, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return null;
    return luaString(state, -1) orelse error.InvalidEffect;
}

fn integerField(state: *lua.lua_State, table: c_int, name: [*:0]const u8, default: i64) !i64 {
    _ = lua.lua_getfield(state, table, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default;
    var valid: c_int = 0;
    const value = lua.lua_tointegerx(state, -1, &valid);
    return if (valid != 0) value else error.InvalidEffect;
}

fn booleanField(state: *lua.lua_State, table: c_int, name: [*:0]const u8, default: bool) !bool {
    _ = lua.lua_getfield(state, table, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default;
    if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) return error.InvalidEffect;
    return lua.lua_toboolean(state, -1) != 0;
}

fn agentState(value: []const u8) !core.schema.AgentReportState {
    if (std.mem.eql(u8, value, "working")) return .working;
    if (std.mem.eql(u8, value, "ready")) return .ready;
    if (std.mem.eql(u8, value, "blocked")) return .blocked;
    return error.InvalidEffect;
}

fn confidence(value: []const u8) !effects.Confidence {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    return error.InvalidEffect;
}

fn notificationLevel(value: []const u8) !core.schema.NotificationLevel {
    if (value.len == 0 or std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "success")) return .success;
    if (std.mem.eql(u8, value, "warning")) return .warning;
    if (std.mem.eql(u8, value, "failure")) return .failure;
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
    if (!validModuleName(name)) return raise(state, "invalid local module name");

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
        if (cursor == relative.len) return raise(state, "module path too long");
        relative[cursor] = if (byte == '.') std.fs.path.sep else byte;
        cursor += 1;
    }
    if (relative.len - cursor < 4) return raise(state, "module path too long");
    @memcpy(relative[cursor..][0..4], ".lua");
    cursor += 4;
    var candidate: [std.fs.max_path_bytes]u8 = undefined;
    const joined = std.fmt.bufPrint(&candidate, "{s}/{s}", .{ host.package_root, relative[0..cursor] }) catch return raise(state, "module path too long");
    var resolved_storage: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = Io.Dir.cwd().realPathFile(host.io, joined, &resolved_storage) catch return raise(state, "cannot resolve local module");
    const resolved = resolved_storage[0..resolved_len];
    if (!pathInside(host.package_root, resolved) or resolved_len == resolved_storage.len) return raise(state, "module escapes package");
    resolved_storage[resolved_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(resolved_storage[0..resolved_len :0]);
    if (lua.luaL_loadfilex(state, path_z, "t") != lua.LUA_OK) return lua.lua_error(state);
    if (lua.lua_pcallk(state, 0, 1, 0, 0, null) != lua.LUA_OK) return lua.lua_error(state);
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
    if (input.len > max_json_bytes) return raise(state, "JSON input is too large");
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, input, .{ .max_value_len = max_json_bytes }) catch return raise(state, "invalid JSON");
    defer parsed.deinit();
    pushJson(state, parsed.value, 0) catch return raise(state, "JSON exceeds depth limit");
    return 1;
}

fn pushJson(state: *lua.lua_State, value: std.json.Value, depth: u8) !void {
    if (depth == 64) return error.JsonDepth;
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

fn setString(state: *lua.lua_State, index: c_int, name: [*:0]const u8, value: []const u8) void {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_pushlstring(state, value.ptr, value.len);
    lua.lua_setfield(state, absolute, name);
}

fn setInteger(state: *lua.lua_State, index: c_int, name: [*:0]const u8, value: anytype) void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushinteger(state, @intCast(value));
    lua.lua_setfield(state, absolute, name);
}

fn setBoolean(state: *lua.lua_State, index: c_int, name: [*:0]const u8, value: bool) void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushboolean(state, @intFromBool(value));
    lua.lua_setfield(state, absolute, name);
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
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
    var previous_dot = false;
    for (name) |byte| {
        if (byte == '.') {
            if (previous_dot) return false;
            previous_dot = true;
        } else {
            previous_dot = false;
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
        }
    }
    return true;
}

fn pathInside(root: []const u8, candidate: []const u8) bool {
    return std.mem.startsWith(u8, candidate, root) and
        (candidate.len == root.len or (candidate.len > root.len and candidate[root.len] == std.fs.path.sep));
}
