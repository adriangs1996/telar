//! Client-owned Lua configuration and callback VM.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const action_mod = @import("action.zig");
const config_model = @import("config_model.zig");
const keybind = @import("keybind.zig");
const kitty = @import("kitty.zig");
const theme_mod = @import("theme.zig");

const Io = std.Io;

pub const api_version: u16 = 2;
pub const default_memory_limit = config_model.default_memory_limit;
pub const default_load_instruction_limit = config_model.default_load_instruction_limit;
pub const default_callback_instruction_limit: u64 = 100_000;
pub const default_callback_deadline_ns: u64 = 10 * std.time.ns_per_ms;
pub const hook_instruction_interval: u32 = 1_000;
pub const max_bindings = config_model.max_bindings;
pub const max_binding_keys = config_model.max_binding_keys;
pub const max_binding_suffix_keys = max_binding_keys - 1;
pub const max_callbacks = max_bindings;
pub const max_callback_effects = config_model.max_callback_effects;
pub const max_expression_keys = config_model.max_expression_keys;
pub const max_expression_paste_bytes = config_model.max_expression_paste_bytes;
pub const max_config_bytes = 1024 * 1024;
pub const max_local_modules = 64;
pub const max_plugins = config_model.max_plugins;
pub const max_plugin_path_bytes = config_model.max_plugin_path_bytes;
pub const max_profile_name_bytes = 64;
pub const max_history_path_bytes = config_model.max_history_path_bytes;
pub const max_proxy_path_bytes = config_model.max_proxy_path_bytes;

pub const ConfiguredBinding = config_model.ConfiguredBinding;
pub const Diagnostic = config_model.Diagnostic;
pub const Snapshot = config_model.Snapshot;
pub const PluginSpec = config_model.PluginSpec;
pub const RuntimeSnapshot = config_model.RuntimeSnapshot;

const Callback = struct {
    registry_ref: c_int,
    expression: bool,
    trigger: [max_binding_keys]keybind.Key = @splat(.plain(.escape)),
    trigger_len: u8 = 0,
};

pub const CallbackContext = config_model.CallbackContext;
pub const EffectBatch = config_model.EffectBatch;
pub const InputKeys = config_model.InputKeys;
pub const InputPaste = config_model.InputPaste;
pub const InputDecision = config_model.InputDecision;
pub const Limits = config_model.Limits;

const Meter = struct {
    used: usize = 0,
    limit: usize = default_memory_limit,
};

/// Owns one Lua generation. Higher-level config parsing and callback IDs are
/// added around this type; the allocator and hook stay the common hard limit.
pub const Vm = struct {
    io: Io,
    state: *lua.lua_State,
    meter: Meter,
    instruction_count: u64 = 0,
    instruction_limit: u64 = default_load_instruction_limit,
    deadline_ns: u64 = 0,

    pub fn init(io: Io, limits: Limits) !*Vm {
        const vm = std.heap.c_allocator.create(Vm) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.destroy(vm);
        vm.* = .{
            .io = io,
            .state = undefined,
            .meter = .{ .limit = limits.memory },
            .instruction_limit = limits.instructions,
            .deadline_ns = monotonic(io) +| limits.deadline_after_ns,
        };
        vm.state = lua.lua_newstate(allocate, vm, 0) orelse return error.OutOfMemory;
        lua.lua_sethook(
            vm.state,
            instructionHook,
            lua.LUA_MASKCOUNT,
            hook_instruction_interval,
        );
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        lua.lua_close(vm.state);
        std.debug.assert(vm.meter.used == 0);
        std.heap.c_allocator.destroy(vm);
    }

    pub fn resetBudget(vm: *Vm, instructions: u64, deadline_after_ns: u64) void {
        vm.instruction_count = 0;
        vm.instruction_limit = instructions;
        vm.deadline_ns = monotonic(vm.io) +| deadline_after_ns;
    }

    pub fn evaluate(vm: *Vm, source: []const u8, name: [*:0]const u8) !void {
        return vm.execute(source, name, 1);
    }

    pub fn execute(vm: *Vm, source: []const u8, name: [*:0]const u8, results: c_int) !void {
        if (lua.luaL_loadbufferx(vm.state, source.ptr, source.len, name, "t") != lua.LUA_OK)
            return error.LuaLoadFailed;
        if (lua.lua_pcallk(vm.state, 0, results, 0, 0, null) != lua.LUA_OK)
            return error.LuaRuntimeFailed;
    }

    pub fn errorMessage(vm: *Vm) []const u8 {
        var len: usize = 0;
        const message = lua.lua_tolstring(vm.state, -1, &len) orelse return "unknown Lua error";
        return message[0..len];
    }

    fn allocate(
        userdata: ?*anyopaque,
        pointer: ?*anyopaque,
        old_size: usize,
        new_size: usize,
    ) callconv(.c) ?*anyopaque {
        const vm: *Vm = @ptrCast(@alignCast(userdata.?));
        if (new_size == 0) {
            std.c.free(pointer);
            vm.meter.used -|= old_size;
            return null;
        }

        const without_old = vm.meter.used -| old_size;
        const next = std.math.add(usize, without_old, new_size) catch return null;
        if (next > vm.meter.limit) return null;
        const result = if (pointer) |existing|
            std.c.realloc(existing, new_size)
        else
            std.c.malloc(new_size);
        if (result != null) vm.meter.used = next;
        return result;
    }

    fn instructionHook(state: ?*lua.lua_State, _: ?*lua.lua_Debug) callconv(.c) void {
        var userdata: ?*anyopaque = null;
        _ = lua.lua_getallocf(state.?, &userdata);
        const vm: *Vm = @ptrCast(@alignCast(userdata.?));
        vm.instruction_count +|= hook_instruction_interval;
        if (vm.instruction_count <= vm.instruction_limit and
            monotonic(vm.io) <= vm.deadline_ns) return;
        _ = lua.lua_pushstring(state.?, "Telar Lua execution budget exceeded");
        _ = lua.lua_error(state.?);
    }
};

pub const Generation = struct {
    gpa: std.mem.Allocator,
    number: u64,
    vm: *Vm,
    snapshot: Snapshot = .{},
    callbacks: [max_callbacks]Callback = undefined,
    callback_count: u16 = 0,
    config_dir: [std.fs.max_path_bytes]u8 = undefined,
    config_dir_len: u16 = 0,
    module_cache_ref: c_int = lua.LUA_NOREF,
    dependencies: [max_local_modules][std.fs.max_path_bytes]u8 = undefined,
    dependency_lens: [max_local_modules]u16 = undefined,
    dependency_mtimes: [max_local_modules]i128 = undefined,
    dependency_count: u8 = 0,
    profile_bytes: [max_profile_name_bytes]u8 = undefined,
    profile_len: u8 = 0,

    pub fn loadSource(
        gpa: std.mem.Allocator,
        io: Io,
        source: []const u8,
        source_name: [*:0]const u8,
        number: u64,
        diagnostic: *Diagnostic,
    ) !*Generation {
        return loadSourceInDir(gpa, io, source, source_name, ".", number, null, diagnostic);
    }

    pub fn loadSourceProfile(
        gpa: std.mem.Allocator,
        io: Io,
        source: []const u8,
        source_name: [*:0]const u8,
        number: u64,
        profile: []const u8,
        diagnostic: *Diagnostic,
    ) !*Generation {
        return loadSourceInDir(gpa, io, source, source_name, ".", number, profile, diagnostic);
    }

    fn loadSourceInDir(
        gpa: std.mem.Allocator,
        io: Io,
        source: []const u8,
        source_name: [*:0]const u8,
        config_dir: []const u8,
        number: u64,
        profile: ?[]const u8,
        diagnostic: *Diagnostic,
    ) !*Generation {
        if (config_dir.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (profile) |name| {
            if (!validProfileName(name)) {
                diagnostic.set("invalid profile name '{s}'", .{name});
                return error.InvalidProfileName;
            }
        }
        const generation = try gpa.create(Generation);
        errdefer gpa.destroy(generation);
        generation.* = .{
            .gpa = gpa,
            .number = number,
            .vm = try Vm.init(io, .{}),
            .config_dir_len = @intCast(config_dir.len),
        };
        @memcpy(generation.config_dir[0..config_dir.len], config_dir);
        if (profile) |name| {
            @memcpy(generation.profile_bytes[0..name.len], name);
            generation.profile_len = @intCast(name.len);
        }
        errdefer generation.vm.deinit();

        generation.openEnvironment() catch |err| {
            diagnostic.set("failed to initialize Lua: {s}", .{@errorName(err)});
            return err;
        };
        generation.vm.resetBudget(default_load_instruction_limit, 100 * std.time.ns_per_ms);
        generation.vm.execute(bootstrap, "@telar/bootstrap.lua", 0) catch |err| {
            diagnostic.set("failed to initialize telar Lua API: {s}", .{generation.vm.errorMessage()});
            return err;
        };
        generation.installRequire();
        generation.vm.execute(source, source_name, 1) catch |err| {
            diagnostic.set("{s}", .{generation.vm.errorMessage()});
            return err;
        };
        generation.parseSnapshot(diagnostic) catch |err| return err;
        generation.syncCallbackTriggers();
        lua.lua_settop(generation.vm.state, 0);
        return generation;
    }

    pub fn loadFile(
        gpa: std.mem.Allocator,
        io: Io,
        path: []const u8,
        number: u64,
        diagnostic: *Diagnostic,
    ) !*Generation {
        return loadFileProfile(gpa, io, path, number, null, diagnostic);
    }

    pub fn loadFileProfile(
        gpa: std.mem.Allocator,
        io: Io,
        path: []const u8,
        number: u64,
        profile: ?[]const u8,
        diagnostic: *Diagnostic,
    ) !*Generation {
        var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const real_path_len = Io.Dir.cwd().realPathFile(io, path, &real_path_buffer) catch |err| {
            diagnostic.set("cannot resolve config '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };
        const real_path = real_path_buffer[0..real_path_len];
        const source = Io.Dir.cwd().readFileAlloc(
            io,
            real_path,
            gpa,
            .limited(max_config_bytes),
        ) catch |err| {
            diagnostic.set("cannot read config '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };
        defer gpa.free(source);
        const config_dir = std.fs.path.dirname(real_path) orelse ".";
        return loadSourceInDir(
            gpa,
            io,
            source,
            "@config.lua",
            config_dir,
            number,
            profile,
            diagnostic,
        );
    }

    pub fn loadSourceAt(
        gpa: std.mem.Allocator,
        io: Io,
        source: []const u8,
        source_name: [*:0]const u8,
        config_dir: []const u8,
        number: u64,
        diagnostic: *Diagnostic,
    ) !*Generation {
        return loadSourceInDir(
            gpa,
            io,
            source,
            source_name,
            config_dir,
            number,
            null,
            diagnostic,
        );
    }

    pub fn deinit(generation: *Generation) void {
        generation.vm.deinit();
        generation.gpa.destroy(generation);
    }

    pub fn dependencyPath(generation: *const Generation, index: usize) ?[]const u8 {
        if (index >= generation.dependency_count) return null;
        return generation.dependencies[index][0..generation.dependency_lens[index]];
    }

    pub fn watchFingerprint(
        generation: *const Generation,
        io: Io,
        config_path: []const u8,
    ) i128 {
        var hasher = std.hash.Wyhash.init(0x74656c61722d6c75);
        updatePathFingerprint(&hasher, io, config_path);
        for (0..generation.dependency_count) |index|
            updatePathFingerprint(&hasher, io, generation.dependencyPath(index).?);
        return @intCast(hasher.final());
    }

    pub fn configDir(generation: *const Generation) []const u8 {
        return generation.config_dir[0..generation.config_dir_len];
    }

    pub fn pluginSlice(generation: *const Generation) []const PluginSpec {
        return generation.snapshot.plugins[0..generation.snapshot.plugin_count];
    }

    fn installRequire(generation: *Generation) void {
        const state = generation.vm.state;
        lua.lua_createtable(state, 0, max_local_modules);
        generation.module_cache_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        lua.lua_pushlightuserdata(state, generation);
        lua.lua_pushcclosure(state, requireLocal, 1);
        lua.lua_setglobal(state, "require");
    }

    pub fn invokeCallback(
        generation: *Generation,
        reference: action_mod.CallbackRef,
        context: CallbackContext,
        diagnostic: *Diagnostic,
    ) !EffectBatch {
        const callback = try generation.prepareCallback(reference, false, context, diagnostic);
        _ = callback;
        const state = generation.vm.state;
        defer lua.lua_settop(state, 0);
        if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
            diagnostic.set("Lua callback failed: {s}", .{generation.vm.errorMessage()});
            return error.LuaCallbackFailed;
        }
        return generation.parseEffectBatch(-1, diagnostic);
    }

    pub fn invokeExpression(
        generation: *Generation,
        reference: action_mod.CallbackRef,
        context: CallbackContext,
        diagnostic: *Diagnostic,
    ) !InputDecision {
        const callback = try generation.prepareCallback(reference, true, context, diagnostic);
        const state = generation.vm.state;
        defer lua.lua_settop(state, 0);
        if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
            diagnostic.set("Lua expression failed: {s}", .{generation.vm.errorMessage()});
            return error.LuaCallbackFailed;
        }
        return parseInputDecision(state, -1, callback, diagnostic);
    }

    fn prepareCallback(
        generation: *Generation,
        reference: action_mod.CallbackRef,
        expression: bool,
        context: CallbackContext,
        diagnostic: *Diagnostic,
    ) !*const Callback {
        if (reference.generation != generation.number or reference.id >= generation.callback_count) {
            diagnostic.set("callback belongs to an obsolete configuration generation", .{});
            return error.StaleCallback;
        }
        const callback = &generation.callbacks[reference.id];
        if (callback.expression != expression) {
            diagnostic.set("callback kind does not match its binding", .{});
            return error.InvalidCallbackKind;
        }
        const state = generation.vm.state;
        lua.lua_settop(state, 0);
        generation.vm.resetBudget(
            default_callback_instruction_limit,
            default_callback_deadline_ns,
        );
        _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, callback.registry_ref);
        pushReadonlyContext(state, context);
        return callback;
    }

    fn parseEffectBatch(
        generation: *Generation,
        index: c_int,
        diagnostic: *Diagnostic,
    ) !EffectBatch {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("Lua callback must return an action or an array of actions", .{});
            return error.InvalidCallbackResult;
        }
        var batch: EffectBatch = .{};
        _ = lua.lua_getfield(state, absolute, "kind");
        const single = lua.lua_type(state, -1) != lua.LUA_TNIL;
        pop(state, 1);
        if (single) {
            batch.items[0] = try generation.parseReturnedAction(absolute, diagnostic);
            batch.len = 1;
            return batch;
        }
        const count = lua.lua_rawlen(state, absolute);
        if (count > max_callback_effects) {
            diagnostic.set("Lua callback exceeds {d} effects", .{max_callback_effects});
            return error.InvalidCallbackResult;
        }
        for (0..count) |effect_index| {
            _ = lua.lua_geti(state, absolute, @intCast(effect_index + 1));
            batch.items[effect_index] = generation.parseReturnedAction(-1, diagnostic) catch |err| {
                pop(state, 1);
                return err;
            };
            pop(state, 1);
        }
        batch.len = @intCast(count);
        return batch;
    }

    fn parseReturnedAction(
        generation: *Generation,
        index: c_int,
        diagnostic: *Diagnostic,
    ) !action_mod.Action {
        if (lua.lua_type(generation.vm.state, index) == lua.LUA_TFUNCTION) {
            diagnostic.set("a callback cannot return another callback", .{});
            return error.InvalidCallbackResult;
        }
        const action = generation.parseAction(index, false, diagnostic) catch
            return error.InvalidCallbackResult;
        return switch (action) {
            .lua_callback, .lua_expr => error.InvalidCallbackResult,
            else => action,
        };
    }

    fn openEnvironment(generation: *Generation) !void {
        const state = generation.vm.state;
        openLibrary(state, "_G", lua.luaopen_base);
        openLibrary(state, lua.LUA_COLIBNAME, lua.luaopen_coroutine);
        openLibrary(state, lua.LUA_MATHLIBNAME, lua.luaopen_math);
        openLibrary(state, lua.LUA_STRLIBNAME, lua.luaopen_string);
        openLibrary(state, lua.LUA_TABLIBNAME, lua.luaopen_table);
        openLibrary(state, lua.LUA_UTF8LIBNAME, lua.luaopen_utf8);
        for ([_][*:0]const u8{
            "collectgarbage",
            "dofile",
            "getmetatable",
            "load",
            "loadfile",
            "print",
            "rawset",
            "setmetatable",
        }) |name| {
            lua.lua_pushnil(state);
            lua.lua_setglobal(state, name);
        }
    }

    fn parseSnapshot(generation: *Generation, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.lua must return a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, -1, &.{ "api_version", "client", "runtime", "plugins", "profiles" }, "config", diagnostic);

        _ = lua.lua_getfield(state, -1, "api_version");
        const version = integer(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("config.api_version must be an integer", .{});
            return error.InvalidConfig;
        };
        pop(state, 1);
        if (version != api_version) {
            diagnostic.set(
                "config.api_version is {d}; this Telar accepts {d}",
                .{ version, api_version },
            );
            return error.IncompatibleConfigApi;
        }

        _ = lua.lua_getfield(state, -1, "plugins");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parsePlugins(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, -1, "client");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseClient(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, -1, "runtime");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseRuntime(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, -1, "profiles");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
            if (generation.profile_len != 0) {
                diagnostic.set("profile '{s}' is not defined", .{generation.profile_bytes[0..generation.profile_len]});
                return error.UnknownProfile;
            }
            return;
        }
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.profiles must be a table", .{});
            return error.InvalidConfig;
        }
        try generation.parseProfiles(-1, diagnostic);
    }

    fn parseProfile(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        try ensureOnlyFields(state, absolute, &.{ "client", "runtime", "plugins" }, "profile", diagnostic);
        _ = lua.lua_getfield(state, absolute, "plugins");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parsePlugins(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "client");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseClient(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "runtime");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseRuntime(-1, diagnostic);
        pop(state, 1);
    }

    fn parseProfiles(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        const base_snapshot = generation.snapshot;
        var selected_snapshot: ?Snapshot = null;
        const selected_name = generation.profile_bytes[0..generation.profile_len];
        lua.lua_pushnil(state);
        while (lua.lua_next(state, absolute) != 0) {
            const name = string(state, -2) orelse {
                pop(state, 2);
                diagnostic.set("config.profiles contains a non-string name", .{});
                return error.InvalidConfig;
            };
            if (!validProfileName(name)) {
                diagnostic.set("invalid profile name '{s}'", .{name});
                pop(state, 2);
                return error.InvalidConfig;
            }
            if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
                diagnostic.set("profile '{s}' must be a table", .{name});
                pop(state, 2);
                return error.InvalidConfig;
            }
            generation.snapshot = base_snapshot;
            generation.parseProfile(-1, diagnostic) catch |err| {
                pop(state, 2);
                return err;
            };
            if (generation.profile_len != 0 and std.mem.eql(u8, name, selected_name))
                selected_snapshot = generation.snapshot;
            pop(state, 1);
        }
        generation.snapshot = if (generation.profile_len == 0)
            base_snapshot
        else
            selected_snapshot orelse {
                diagnostic.set("profile '{s}' is not defined", .{selected_name});
                return error.UnknownProfile;
            };
    }

    fn parsePlugins(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.plugins must be an array", .{});
            return error.InvalidConfig;
        }
        const count = lua.lua_rawlen(state, absolute);
        if (count > max_plugins) {
            diagnostic.set("config.plugins exceeds {d} entries", .{max_plugins});
            return error.InvalidConfig;
        }
        generation.snapshot.plugin_count = 0;
        for (0..count) |plugin_index| {
            _ = lua.lua_geti(state, absolute, @intCast(plugin_index + 1));
            defer pop(state, 1);
            if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
                diagnostic.set("plugin {d} must be a telar.plugin value", .{plugin_index + 1});
                return error.InvalidConfig;
            }
            const plugin_table = lua.lua_absindex(state, -1);
            try ensureOnlyFields(
                state,
                plugin_table,
                &.{ "path", "enabled" },
                "plugin",
                diagnostic,
            );
            const path = try requiredStringField(state, plugin_table, "path", diagnostic);
            if (path.len == 0 or path.len > max_plugin_path_bytes) {
                diagnostic.set("plugin {d} path is invalid", .{plugin_index + 1});
                return error.InvalidConfig;
            }
            var spec: PluginSpec = .{ .path_len = @intCast(path.len) };
            @memcpy(spec.path_bytes[0..path.len], path);
            _ = lua.lua_getfield(state, plugin_table, "enabled");
            if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
                if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                    pop(state, 1);
                    diagnostic.set("plugin {d}.enabled must be a boolean", .{plugin_index + 1});
                    return error.InvalidConfig;
                }
                spec.enabled = lua.lua_toboolean(state, -1) != 0;
            }
            pop(state, 1);
            generation.snapshot.plugins[plugin_index] = spec;
        }
        generation.snapshot.plugin_count = @intCast(count);
    }

    fn parseRuntime(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, absolute, &.{ "graphics", "history", "proxy" }, "config.runtime", diagnostic);
        _ = lua.lua_getfield(state, absolute, "history");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseHistory(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "proxy");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseProxy(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "graphics");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.graphics must be a table", .{});
            return error.InvalidConfig;
        }
        const graphics = lua.lua_absindex(state, -1);
        try ensureOnlyFields(
            state,
            graphics,
            &.{ "pane_mib", "global_mib" },
            "config.runtime.graphics",
            diagnostic,
        );
        generation.snapshot.runtime.graphics_pane_bytes = try optionalMebibytes(
            state,
            graphics,
            "pane_mib",
            generation.snapshot.runtime.graphics_pane_bytes,
            diagnostic,
        );
        generation.snapshot.runtime.graphics_global_bytes = try optionalMebibytes(
            state,
            graphics,
            "global_mib",
            generation.snapshot.runtime.graphics_global_bytes,
            diagnostic,
        );
        const runtime = generation.snapshot.runtime;
        if (runtime.graphics_pane_bytes < 2 * 1024 * 1024 or
            runtime.graphics_pane_bytes > core.graphics.max_image_bytes_per_pane or
            runtime.graphics_global_bytes < runtime.graphics_pane_bytes or
            runtime.graphics_global_bytes > core.graphics.max_image_bytes_global)
        {
            diagnostic.set("runtime graphics limits are outside Telar's safe bounds", .{});
            return error.InvalidConfig;
        }
    }

    fn parseProxy(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.proxy must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "enabled", "ca_dir" },
            "config.runtime.proxy",
            diagnostic,
        );
        _ = lua.lua_getfield(state, absolute, "enabled");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.runtime.proxy.enabled must be a boolean", .{});
                return error.InvalidConfig;
            }
            generation.snapshot.runtime.proxy_enabled = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "ca_dir");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
        const path = string(state, -1) orelse {
            diagnostic.set("config.runtime.proxy.ca_dir must be a string", .{});
            return error.InvalidConfig;
        };
        if (path.len == 0 or path.len > max_proxy_path_bytes or
            std.mem.indexOfScalar(u8, path, 0) != null)
        {
            diagnostic.set("config.runtime.proxy.ca_dir is invalid", .{});
            return error.InvalidConfig;
        }
        @memcpy(generation.snapshot.runtime.proxy_ca_dir_bytes[0..path.len], path);
        generation.snapshot.runtime.proxy_ca_dir_len = @intCast(path.len);
    }

    fn parseHistory(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.history must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, absolute, &.{"path"}, "config.runtime.history", diagnostic);
        const path = try requiredStringField(state, absolute, "path", diagnostic);
        if (path.len == 0 or path.len > max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
            diagnostic.set("config.runtime.history.path is invalid", .{});
            return error.InvalidConfig;
        }
        @memcpy(generation.snapshot.runtime.history_path_bytes[0..path.len], path);
        generation.snapshot.runtime.history_path_len = @intCast(path.len);
    }

    fn parseClient(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "prefix", "theme", "sidebar", "pane_gaps", "input", "keybindings" },
            "config.client",
            diagnostic,
        );

        _ = lua.lua_getfield(state, absolute, "prefix");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parsePrefix(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "theme");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            generation.snapshot.theme = try parseTheme(state, -1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "sidebar");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseSidebar(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "pane_gaps");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.client.pane_gaps must be a boolean", .{});
                return error.InvalidConfig;
            }
            generation.snapshot.pane_gaps = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "input");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseInputOptions(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "keybindings");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseBindings(-1, diagnostic);
        pop(state, 1);
    }

    fn parsePrefix(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const value = string(generation.vm.state, index) orelse {
            diagnostic.set("config.client.prefix must be a string", .{});
            return error.InvalidConfig;
        };
        const prefix = keybind.parseKey(value) catch |err| {
            diagnostic.set("invalid config.client.prefix: {s}", .{@errorName(err)});
            return error.InvalidConfig;
        };
        generation.snapshot.prefix = prefix;
        for (generation.snapshot.bindings[0..generation.snapshot.binding_count], 0..) |*binding, binding_index| {
            if (generation.snapshot.bindings_prefixed[binding_index])
                binding.keys[0] = prefix;
        }
    }

    fn parseInputOptions(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.input must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "escape_timeout_ms", "sequence_timeout_ms" },
            "config.client.input",
            diagnostic,
        );
        generation.snapshot.input_escape_timeout_ns = try optionalMilliseconds(
            state,
            absolute,
            "escape_timeout_ms",
            generation.snapshot.input_escape_timeout_ns,
            1,
            1000,
            diagnostic,
        );
        generation.snapshot.input_sequence_timeout_ns = try optionalMilliseconds(
            state,
            absolute,
            "sequence_timeout_ms",
            generation.snapshot.input_sequence_timeout_ns,
            10,
            10_000,
            diagnostic,
        );
    }

    fn parseSidebar(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.sidebar must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "visible", "renderer" },
            "config.client.sidebar",
            diagnostic,
        );
        _ = lua.lua_getfield(state, absolute, "visible");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.client.sidebar.visible must be a boolean", .{});
                return error.InvalidConfig;
            }
            generation.snapshot.sidebar_visible = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "renderer");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const value = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.client.sidebar.renderer must be a string", .{});
                return error.InvalidConfig;
            };
            generation.snapshot.sidebar_rendering = kitty.SidebarRendering.parse(value) catch {
                diagnostic.set("unknown sidebar renderer '{s}'", .{value});
                pop(state, 1);
                return error.InvalidConfig;
            };
        }
        pop(state, 1);
    }

    fn parseBindings(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.keybindings must be an array", .{});
            return error.InvalidConfig;
        }
        const count = lua.lua_rawlen(state, absolute);
        if (count > max_bindings) {
            diagnostic.set("config.client.keybindings exceeds {d} entries", .{max_bindings});
            return error.InvalidConfig;
        }
        generation.snapshot.bindings_configured = true;
        generation.snapshot.binding_count = 0;
        for (0..count) |binding_index| {
            _ = lua.lua_geti(state, absolute, @intCast(binding_index + 1));
            const parsed = generation.parseBinding(
                -1,
                binding_index,
                diagnostic,
            ) catch |err| {
                pop(state, 1);
                return err;
            };
            generation.snapshot.bindings[binding_index] = parsed.binding;
            generation.snapshot.bindings_prefixed[binding_index] = parsed.prefixed;
            pop(state, 1);
        }
        generation.snapshot.binding_count = @intCast(count);
    }

    const ParsedBinding = struct {
        binding: ConfiguredBinding,
        prefixed: bool,
    };

    fn parseBinding(
        generation: *Generation,
        index: c_int,
        binding_index: usize,
        diagnostic: *Diagnostic,
    ) !ParsedBinding {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("keybinding {d} must be a telar.bind value", .{binding_index + 1});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "keys", "action", "expression", "prefixed" },
            "keybinding",
            diagnostic,
        );

        _ = lua.lua_getfield(state, absolute, "prefixed");
        const prefixed = if (lua.lua_type(state, -1) == lua.LUA_TBOOLEAN)
            lua.lua_toboolean(state, -1) != 0
        else {
            pop(state, 1);
            diagnostic.set("keybinding {d}.prefixed must be a boolean", .{binding_index + 1});
            return error.InvalidConfig;
        };
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "keys");
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            pop(state, 1);
            diagnostic.set("keybinding {d}.keys must be an array", .{binding_index + 1});
            return error.InvalidConfig;
        }
        const key_count = lua.lua_rawlen(state, -1);
        const key_limit: usize = if (prefixed) max_binding_suffix_keys else max_binding_keys;
        if (key_count == 0 or key_count > key_limit) {
            pop(state, 1);
            diagnostic.set(
                "keybinding {d}.keys must contain 1..{d} keys",
                .{ binding_index + 1, key_limit },
            );
            return error.InvalidConfig;
        }
        var keys: [max_binding_keys]keybind.Key = undefined;
        const key_offset: usize = @intFromBool(prefixed);
        if (prefixed) keys[0] = generation.snapshot.prefix;
        for (0..key_count) |key_index| {
            _ = lua.lua_geti(state, -1, @intCast(key_index + 1));
            const name = string(state, -1) orelse {
                pop(state, 2);
                diagnostic.set(
                    "keybinding {d}.keys[{d}] must be a string",
                    .{ binding_index + 1, key_index + 1 },
                );
                return error.InvalidConfig;
            };
            keys[key_offset + key_index] = keybind.parseKey(name) catch |err| {
                pop(state, 2);
                diagnostic.set(
                    "invalid keybinding {d}: {s}",
                    .{ binding_index + 1, @errorName(err) },
                );
                return error.InvalidConfig;
            };
            pop(state, 1);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "expression");
        const expression = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
            false
        else if (lua.lua_type(state, -1) == lua.LUA_TBOOLEAN)
            lua.lua_toboolean(state, -1) != 0
        else {
            pop(state, 1);
            diagnostic.set("keybinding {d}.expression must be a boolean", .{binding_index + 1});
            return error.InvalidConfig;
        };
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "action");
        const action = generation.parseAction(-1, expression, diagnostic) catch |err| {
            pop(state, 1);
            return err;
        };
        pop(state, 1);
        const total_key_count = key_offset + key_count;
        const binding = ConfiguredBinding.init(keys[0..total_key_count], action) catch |err| {
            diagnostic.set("invalid keybinding {d}: {s}", .{ binding_index + 1, @errorName(err) });
            return error.InvalidConfig;
        };
        switch (binding.action) {
            .lua_callback, .lua_expr => |reference| {
                const callback = &generation.callbacks[reference.id];
                @memcpy(callback.trigger[0..binding.len], binding.keys[0..binding.len]);
                callback.trigger_len = binding.len;
            },
            else => {},
        }
        return .{ .binding = binding, .prefixed = prefixed };
    }

    fn syncCallbackTriggers(generation: *Generation) void {
        for (generation.snapshot.bindings[0..generation.snapshot.binding_count]) |*binding| switch (binding.action) {
            .lua_callback, .lua_expr => |reference| {
                const callback = &generation.callbacks[reference.id];
                @memcpy(callback.trigger[0..binding.len], binding.keys[0..binding.len]);
                callback.trigger_len = binding.len;
            },
            else => {},
        };
    }

    fn parseAction(
        generation: *Generation,
        index: c_int,
        expression: bool,
        diagnostic: *Diagnostic,
    ) !action_mod.Action {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) == lua.LUA_TFUNCTION) {
            if (generation.callback_count == max_callbacks) {
                diagnostic.set("configuration exceeds {d} Lua callbacks", .{max_callbacks});
                return error.InvalidConfig;
            }
            lua.lua_pushvalue(state, absolute);
            const registry_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
            const id = generation.callback_count;
            generation.callbacks[id] = .{
                .registry_ref = registry_ref,
                .expression = expression,
            };
            generation.callback_count += 1;
            const reference: action_mod.CallbackRef = .{
                .generation = generation.number,
                .id = id,
            };
            return if (expression)
                .{ .lua_expr = reference }
            else
                .{ .lua_callback = reference };
        }

        if (string(state, absolute)) |name| {
            if (expression) {
                diagnostic.set("expression binding action must be a Lua function", .{});
                return error.InvalidConfig;
            }
            return action_mod.Action.parse(name) catch {
                diagnostic.set("unknown action '{s}'", .{name});
                return error.InvalidConfig;
            };
        }

        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("keybinding action must be a string, action, or function", .{});
            return error.InvalidConfig;
        }
        if (expression) {
            diagnostic.set("expression binding action must be a Lua function", .{});
            return error.InvalidConfig;
        }

        _ = lua.lua_getfield(state, absolute, "kind");
        const kind = string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("action.kind must be a string", .{});
            return error.InvalidConfig;
        };
        defer pop(state, 1);

        if (std.mem.eql(u8, kind, "split-pane")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "direction" }, "action", diagnostic);
            const direction = try requiredStringField(state, absolute, "direction", diagnostic);
            return .{ .split_pane = if (std.mem.eql(u8, direction, "horizontal"))
                .horizontal
            else if (std.mem.eql(u8, direction, "vertical"))
                .vertical
            else {
                diagnostic.set("split-pane direction must be horizontal or vertical", .{});
                return error.InvalidConfig;
            } };
        }
        if (std.mem.eql(u8, kind, "focus-pane") or
            std.mem.eql(u8, kind, "resize-pane"))
        {
            try ensureOnlyFields(state, absolute, &.{ "kind", "direction" }, "action", diagnostic);
            const direction = try requiredStringField(state, absolute, "direction", diagnostic);
            const parsed_direction: action_mod.Direction = if (std.mem.eql(u8, direction, "left"))
                .left
            else if (std.mem.eql(u8, direction, "right"))
                .right
            else if (std.mem.eql(u8, direction, "up"))
                .up
            else if (std.mem.eql(u8, direction, "down"))
                .down
            else {
                diagnostic.set(
                    "{s} direction must be left, right, up, or down",
                    .{kind},
                );
                return error.InvalidConfig;
            };
            return if (std.mem.eql(u8, kind, "focus-pane"))
                .{ .focus_pane = parsed_direction }
            else
                .{ .resize_pane = parsed_direction };
        }
        if (std.mem.eql(u8, kind, "select-tab")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "index" }, "action", diagnostic);
            const one_based = try requiredIntegerField(state, absolute, "index", diagnostic);
            if (one_based <= 0 or one_based > 256) {
                diagnostic.set("select-tab index must be in 1..256", .{});
                return error.InvalidConfig;
            }
            return .{ .select_tab = @intCast(one_based - 1) };
        }
        if (std.mem.eql(u8, kind, "select-workspace")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "index" }, "action", diagnostic);
            const one_based = try requiredIntegerField(state, absolute, "index", diagnostic);
            if (one_based <= 0 or one_based > 256) {
                diagnostic.set("select-workspace index must be in 1..256", .{});
                return error.InvalidConfig;
            }
            return .{ .select_workspace = @intCast(one_based - 1) };
        }
        if (std.mem.eql(u8, kind, "select-tab-offset")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "offset" }, "action", diagnostic);
            const offset = try requiredIntegerField(state, absolute, "offset", diagnostic);
            if (offset < std.math.minInt(i8) or offset > std.math.maxInt(i8)) {
                diagnostic.set("select-tab-offset does not fit in i8", .{});
                return error.InvalidConfig;
            }
            return .{ .select_tab_offset = @intCast(offset) };
        }
        if (std.mem.eql(u8, kind, "move-tab")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "direction" }, "action", diagnostic);
            const direction = try requiredStringField(state, absolute, "direction", diagnostic);
            return .{ .move_tab = if (std.mem.eql(u8, direction, "previous"))
                .previous
            else if (std.mem.eql(u8, direction, "next"))
                .next
            else {
                diagnostic.set("move-tab direction must be previous or next", .{});
                return error.InvalidConfig;
            } };
        }
        if (std.mem.eql(u8, kind, "plugin")) {
            try ensureOnlyFields(
                state,
                absolute,
                &.{ "kind", "plugin", "action" },
                "action",
                diagnostic,
            );
            const plugin_name = try requiredStringField(state, absolute, "plugin", diagnostic);
            const action_name = try requiredStringField(state, absolute, "action", diagnostic);
            return .{ .plugin = .{
                .plugin = core.plugin.stableId(plugin_name),
                .action = core.plugin.stableId(action_name),
            } };
        }
        const action = action_mod.Action.parse(kind) catch {
            diagnostic.set("unknown action kind '{s}'", .{kind});
            return error.InvalidConfig;
        };
        try ensureOnlyFields(state, absolute, &.{"kind"}, "action", diagnostic);
        return action;
    }
};

pub fn defaultPath(
    environ: std.process.Environ,
    buffer: []u8,
) ![]const u8 {
    return resolveDefaultPath(
        environ.getPosix("TELAR_DEVELOPMENT_CONFIG"),
        environ.getPosix("XDG_CONFIG_HOME"),
        environ.getPosix("HOME"),
        buffer,
    );
}

fn resolveDefaultPath(
    development: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
    buffer: []u8,
) ![]const u8 {
    if (development) |path| {
        if (path.len != 0) return std.fmt.bufPrint(buffer, "{s}", .{path});
    }
    if (xdg_config_home) |base| {
        if (base.len != 0)
            return std.fmt.bufPrint(buffer, "{s}/telar/config.lua", .{base});
    }
    const home_path = home orelse return error.HomeDirectoryUnavailable;
    if (home_path.len == 0) return error.HomeDirectoryUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.config/telar/config.lua", .{home_path});
}

const bootstrap =
    \\local telar = {}
    \\telar.action = {}
    \\telar.input = {}
    \\function telar.config(value) return value end
    \\function telar.theme(value) return value end
    \\function telar.plugin(value) return value end
    \\function telar.bind(keys, action)
    \\  return { keys = keys, action = action, expression = false, prefixed = true }
    \\end
    \\function telar.bind_expr(keys, callback)
    \\  return { keys = keys, action = callback, expression = true, prefixed = true }
    \\end
    \\function telar.bind_global(keys, action)
    \\  return { keys = keys, action = action, expression = false, prefixed = false }
    \\end
    \\function telar.bind_expr_global(keys, callback)
    \\  return { keys = keys, action = callback, expression = true, prefixed = false }
    \\end
    \\function telar.input.consume() return { input_kind = "consume" } end
    \\function telar.input.forward() return { input_kind = "forward" } end
    \\function telar.input.key(value)
    \\  return { input_kind = "keys", keys = { value } }
    \\end
    \\function telar.input.keys(values)
    \\  return { input_kind = "keys", keys = values }
    \\end
    \\function telar.input.paste(value)
    \\  return { input_kind = "paste", text = value }
    \\end
    \\function telar.action.split_pane(options)
    \\  return { kind = "split-pane", direction = options.direction }
    \\end
    \\function telar.action.focus_pane(options)
    \\  return { kind = "focus-pane", direction = options.direction }
    \\end
    \\function telar.action.resize_pane(options)
    \\  return { kind = "resize-pane", direction = options.direction }
    \\end
    \\function telar.action.select_tab(options)
    \\  return { kind = "select-tab", index = options.index }
    \\end
    \\function telar.action.select_workspace(options)
    \\  return { kind = "select-workspace", index = options.index }
    \\end
    \\function telar.action.select_tab_offset(options)
    \\  return { kind = "select-tab-offset", offset = options.offset }
    \\end
    \\function telar.action.move_tab(options)
    \\  return { kind = "move-tab", direction = options.direction }
    \\end
    \\function telar.action.plugin(options)
    \\  return { kind = "plugin", plugin = options.plugin, action = options.action }
    \\end
    \\for _, name in ipairs({
    \\  "toggle-pane-fullscreen", "toggle-sidebar", "toggle-workspace-list",
    \\  "new-workspace", "rename-workspace", "close-pane", "new-tab", "rename-tab", "close-tab", "detach", "copy-mode",
    \\}) do
    \\  local stable_name = name
    \\  telar.action[name:gsub("-", "_")] = function()
    \\    return { kind = stable_name }
    \\  end
    \\end
    \\_G.telar = telar
    \\_G.require = function(name)
    \\  if name == "telar" then return telar end
    \\  error("module '" .. tostring(name) .. "' is not available", 2)
    \\end
;

fn requireLocal(state: ?*lua.lua_State) callconv(.c) c_int {
    const lua_state = state.?;
    const context_ptr = lua.lua_touserdata(lua_state, lua.lua_upvalueindex(1)) orelse
        return raiseLua(lua_state, "missing Telar require context");
    const generation: *Generation = @ptrCast(@alignCast(context_ptr));
    const name = string(lua_state, 1) orelse
        return raiseLua(lua_state, "require expects a module name");
    if (std.mem.eql(u8, name, "telar")) {
        _ = lua.lua_getglobal(lua_state, "telar");
        return 1;
    }
    if (!validModuleName(name))
        return raiseLua(lua_state, "module names may contain letters, digits, '_', '-', and '.' only");

    _ = lua.lua_rawgeti(lua_state, lua.LUA_REGISTRYINDEX, generation.module_cache_ref);
    _ = lua.lua_pushlstring(lua_state, name.ptr, name.len);
    _ = lua.lua_rawget(lua_state, -2);
    if (lua.lua_type(lua_state, -1) != lua.LUA_TNIL) {
        lua.lua_remove(lua_state, -2);
        return 1;
    }
    pop(lua_state, 1);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cursor: usize = 0;
    const config_dir = generation.config_dir[0..generation.config_dir_len];
    if (config_dir.len != 0 and !std.mem.eql(u8, config_dir, ".")) {
        if (config_dir.len + 1 > path_buffer.len)
            return raiseLua(lua_state, "module path is too long");
        @memcpy(path_buffer[0..config_dir.len], config_dir);
        cursor = config_dir.len;
        path_buffer[cursor] = std.fs.path.sep;
        cursor += 1;
    }
    if (name.len + ".lua".len > path_buffer.len - cursor)
        return raiseLua(lua_state, "module path is too long");
    for (name) |byte| {
        path_buffer[cursor] = if (byte == '.') std.fs.path.sep else byte;
        cursor += 1;
    }
    @memcpy(path_buffer[cursor..][0..".lua".len], ".lua");
    cursor += ".lua".len;
    if (cursor == path_buffer.len) return raiseLua(lua_state, "module path is too long");
    path_buffer[cursor] = 0;
    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = Io.Dir.cwd().realPathFile(
        generation.vm.io,
        path_buffer[0..cursor],
        &resolved_buffer,
    ) catch return raiseLua(lua_state, "cannot resolve local configuration module");
    const resolved = resolved_buffer[0..resolved_len];
    if (!pathInside(generation.configDir(), resolved))
        return raiseLua(lua_state, "local configuration module escapes the configuration directory");
    if (resolved_len == resolved_buffer.len)
        return raiseLua(lua_state, "module path is too long");
    resolved_buffer[resolved_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(resolved_buffer[0..resolved_len :0]);

    if (lua.luaL_loadfilex(lua_state, path_z, "t") != lua.LUA_OK)
        return lua.lua_error(lua_state);
    if (lua.lua_pcallk(lua_state, 0, 1, 0, 0, null) != lua.LUA_OK)
        return lua.lua_error(lua_state);
    if (lua.lua_type(lua_state, -1) == lua.LUA_TNIL) {
        pop(lua_state, 1);
        lua.lua_pushboolean(lua_state, 1);
    }

    if (generation.dependency_count == max_local_modules)
        return raiseLua(lua_state, "configuration requires too many local modules");
    const dependency_index = generation.dependency_count;
    @memcpy(generation.dependencies[dependency_index][0..resolved_len], resolved);
    generation.dependency_lens[dependency_index] = @intCast(resolved_len);
    const stat = Io.Dir.cwd().statFile(generation.vm.io, resolved, .{}) catch
        return raiseLua(lua_state, "cannot stat loaded configuration module");
    generation.dependency_mtimes[dependency_index] = stat.mtime.nanoseconds;
    generation.dependency_count += 1;

    _ = lua.lua_pushlstring(lua_state, name.ptr, name.len);
    lua.lua_pushvalue(lua_state, -2);
    lua.lua_rawset(lua_state, -4);
    lua.lua_remove(lua_state, -2);
    return 1;
}

fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
    var previous_dot = false;
    for (name) |byte| {
        if (byte == '.') {
            if (previous_dot) return false;
            previous_dot = true;
            continue;
        }
        previous_dot = false;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn pathInside(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    return candidate.len == root.len or
        (candidate.len > root.len and candidate[root.len] == std.fs.path.sep);
}

fn updatePathFingerprint(hasher: *std.hash.Wyhash, io: Io, path: []const u8) void {
    hasher.update(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
        hasher.update("\x00missing");
        return;
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
}

fn validProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_bytes) return false;
    for (name) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

fn raiseLua(state: *lua.lua_State, message: [*:0]const u8) c_int {
    _ = lua.lua_pushstring(state, message);
    return lua.lua_error(state);
}

fn openLibrary(
    state: *lua.lua_State,
    name: [*:0]const u8,
    function: lua.lua_CFunction,
) void {
    lua.luaL_requiref(state, name, function, 1);
    pop(state, 1);
}

fn pop(state: *lua.lua_State, count: c_int) void {
    lua.lua_settop(state, -count - 1);
}

fn string(state: *lua.lua_State, index: c_int) ?[]const u8 {
    if (lua.lua_type(state, index) != lua.LUA_TSTRING) return null;
    var len: usize = 0;
    const value = lua.lua_tolstring(state, index, &len) orelse return null;
    return value[0..len];
}

fn integer(state: *lua.lua_State, index: c_int) ?lua.lua_Integer {
    var is_number: c_int = 0;
    const value = lua.lua_tointegerx(state, index, &is_number);
    return if (is_number == 1) value else null;
}

fn requiredStringField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    diagnostic: *Diagnostic,
) ![]const u8 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    const value = string(state, -1) orelse {
        pop(state, 1);
        diagnostic.set("action.{s} must be a string", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
    pop(state, 1);
    return value;
}

fn requiredIntegerField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    diagnostic: *Diagnostic,
) !lua.lua_Integer {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    const value = integer(state, -1) orelse {
        pop(state, 1);
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
    pop(state, 1);
    return value;
}

fn optionalMebibytes(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    default: usize,
    diagnostic: *Diagnostic,
) !usize {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default;
    const value = integer(state, -1) orelse {
        diagnostic.set("runtime graphics {s} must be an integer", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
    if (value <= 0 or value > std.math.maxInt(usize) / (1024 * 1024)) {
        diagnostic.set("runtime graphics {s} is out of range", .{std.mem.span(name)});
        return error.InvalidConfig;
    }
    return @as(usize, @intCast(value)) * 1024 * 1024;
}

fn optionalMilliseconds(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    default_ns: u64,
    minimum_ms: u64,
    maximum_ms: u64,
    diagnostic: *Diagnostic,
) !u64 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default_ns;
    const value = integer(state, -1) orelse {
        diagnostic.set("client input {s} must be an integer", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
    if (value < minimum_ms or value > maximum_ms) {
        diagnostic.set(
            "client input {s} must be in {d}..{d} milliseconds",
            .{ std.mem.span(name), minimum_ms, maximum_ms },
        );
        return error.InvalidConfig;
    }
    return @as(u64, @intCast(value)) * std.time.ns_per_ms;
}

fn ensureOnlyFields(
    state: *lua.lua_State,
    index: c_int,
    allowed: []const []const u8,
    path: []const u8,
    diagnostic: *Diagnostic,
) !void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        const key = string(state, -2) orelse {
            pop(state, 2);
            diagnostic.set("{s} contains a non-string field", .{path});
            return error.InvalidConfig;
        };
        const known = for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break true;
        } else false;
        pop(state, 1);
        if (!known) {
            diagnostic.set("unknown field {s}.{s}", .{ path, key });
            pop(state, 1);
            return error.InvalidConfig;
        }
    }
}

fn parseTheme(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !theme_mod.Theme {
    const absolute = lua.lua_absindex(state, index);
    if (string(state, absolute)) |name| return theme_mod.fromName(name) orelse {
        diagnostic.set("unknown theme '{s}'", .{name});
        return error.InvalidConfig;
    };
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.theme must be a name or table", .{});
        return error.InvalidConfig;
    }
    try ensureOnlyFields(state, absolute, &.{ "base", "colors" }, "config.client.theme", diagnostic);
    _ = lua.lua_getfield(state, absolute, "base");
    const base_name = string(state, -1) orelse {
        pop(state, 1);
        diagnostic.set("config.client.theme.base must be a string", .{});
        return error.InvalidConfig;
    };
    var result = theme_mod.fromName(base_name) orelse {
        diagnostic.set("unknown base theme '{s}'", .{base_name});
        pop(state, 1);
        return error.InvalidConfig;
    };
    pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "colors");
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        pop(state, 1);
        return result;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        pop(state, 1);
        diagnostic.set("config.client.theme.colors must be a table", .{});
        return error.InvalidConfig;
    }
    try ensureThemeColorFields(state, -1, diagnostic);
    var overrides: theme_mod.Overrides = .{};
    inline for (std.meta.fields(theme_mod.Overrides)) |field| {
        _ = lua.lua_getfield(state, -1, field.name);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            @field(overrides, field.name) = try parseColor(state, -1, field.name, diagnostic);
        pop(state, 1);
    }
    pop(state, 1);
    result = result.withOverrides(overrides);
    return result;
}

fn ensureThemeColorFields(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        const key = string(state, -2) orelse {
            pop(state, 2);
            diagnostic.set("theme colors contain a non-string field", .{});
            return error.InvalidConfig;
        };
        const known = inline for (std.meta.fields(theme_mod.Overrides)) |field| {
            if (std.mem.eql(u8, key, field.name)) break true;
        } else false;
        pop(state, 1);
        if (!known) {
            diagnostic.set("unknown theme color '{s}'", .{key});
            pop(state, 1);
            return error.InvalidConfig;
        }
    }
}

fn parseColor(
    state: *lua.lua_State,
    index: c_int,
    field: []const u8,
    diagnostic: *Diagnostic,
) !core.ui.Color {
    const value = string(state, index) orelse {
        diagnostic.set("theme color {s} must be a string", .{field});
        return error.InvalidConfig;
    };
    if (std.mem.eql(u8, value, "default")) return .default;
    if (value.len != 7 or value[0] != '#') {
        diagnostic.set("theme color {s} must be #RRGGBB or default", .{field});
        return error.InvalidConfig;
    }
    const rgb = std.fmt.parseUnsigned(u24, value[1..], 16) catch {
        diagnostic.set("theme color {s} contains invalid hexadecimal digits", .{field});
        return error.InvalidConfig;
    };
    return .{ .rgb = .{
        @intCast((rgb >> 16) & 0xff),
        @intCast((rgb >> 8) & 0xff),
        @intCast(rgb & 0xff),
    } };
}

fn pushReadonlyContext(state: *lua.lua_State, context: CallbackContext) void {
    lua.lua_createtable(state, 0, 5);
    setBooleanField(state, -1, "sidebar_visible", context.sidebar_visible);
    setIntegerField(state, -1, "tab_count", context.tab_count);
    setIntegerField(state, -1, "active_tab_index", @as(u32, context.active_tab_index) + 1);
    setIntegerField(state, -1, "pane_count", context.pane_count);
    setIntegerField(state, -1, "focused_pane_id", context.focused_pane_id);

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

fn setBooleanField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    value: bool,
) void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushboolean(state, @intFromBool(value));
    lua.lua_setfield(state, absolute, name);
}

fn setIntegerField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    value: anytype,
) void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushinteger(state, @intCast(value));
    lua.lua_setfield(state, absolute, name);
}

fn readonlyNewIndex(state: ?*lua.lua_State) callconv(.c) c_int {
    _ = lua.lua_pushstring(state.?, "callback context is immutable");
    return lua.lua_error(state.?);
}

fn parseInputDecision(
    state: *lua.lua_State,
    index: c_int,
    callback: *const Callback,
    diagnostic: *Diagnostic,
) !InputDecision {
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("Lua expression must return a telar.input value", .{});
        return error.InvalidExpressionResult;
    }
    const kind = try requiredStringField(state, absolute, "input_kind", diagnostic);
    if (std.mem.eql(u8, kind, "consume")) {
        try ensureOnlyFields(state, absolute, &.{"input_kind"}, "input decision", diagnostic);
        return .consume;
    }
    if (std.mem.eql(u8, kind, "forward")) {
        try ensureOnlyFields(state, absolute, &.{"input_kind"}, "input decision", diagnostic);
        var keys: InputKeys = .{};
        @memcpy(keys.items[0..callback.trigger_len], callback.trigger[0..callback.trigger_len]);
        keys.len = callback.trigger_len;
        return .{ .forward_binding = keys };
    }
    if (std.mem.eql(u8, kind, "keys")) {
        try ensureOnlyFields(state, absolute, &.{ "input_kind", "keys" }, "input decision", diagnostic);
        _ = lua.lua_getfield(state, absolute, "keys");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("input decision keys must be an array", .{});
            return error.InvalidExpressionResult;
        }
        const count = lua.lua_rawlen(state, -1);
        if (count == 0 or count > max_expression_keys) {
            diagnostic.set("input decision must contain 1..{d} keys", .{max_expression_keys});
            return error.InvalidExpressionResult;
        }
        var keys: InputKeys = .{};
        for (0..count) |key_index| {
            _ = lua.lua_geti(state, -1, @intCast(key_index + 1));
            const value = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("input decision key {d} must be a string", .{key_index + 1});
                return error.InvalidExpressionResult;
            };
            keys.items[key_index] = keybind.parseKey(value) catch |err| {
                diagnostic.set("invalid input decision key {d}: {s}", .{ key_index + 1, @errorName(err) });
                pop(state, 1);
                return error.InvalidExpressionResult;
            };
            pop(state, 1);
        }
        keys.len = @intCast(count);
        return .{ .keys = keys };
    }
    if (std.mem.eql(u8, kind, "paste")) {
        try ensureOnlyFields(state, absolute, &.{ "input_kind", "text" }, "input decision", diagnostic);
        _ = lua.lua_getfield(state, absolute, "text");
        defer pop(state, 1);
        const value = string(state, -1) orelse {
            diagnostic.set("input decision paste text must be a string", .{});
            return error.InvalidExpressionResult;
        };
        if (value.len > max_expression_paste_bytes) {
            diagnostic.set("input decision paste exceeds {d} bytes", .{max_expression_paste_bytes});
            return error.InvalidExpressionResult;
        }
        var paste: InputPaste = .{};
        @memcpy(paste.bytes[0..value.len], value);
        paste.len = @intCast(value.len);
        return .{ .paste = paste };
    }
    diagnostic.set("unknown input decision '{s}'", .{kind});
    return error.InvalidExpressionResult;
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

test "development config path overrides user config lookup" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/repo/dev/config.lua",
        try resolveDefaultPath(
            "/repo/dev/config.lua",
            "/xdg",
            "/home/user",
            &buffer,
        ),
    );
    try std.testing.expectEqualStrings(
        "/xdg/telar/config.lua",
        try resolveDefaultPath("", "/xdg", "/home/user", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/home/user/.config/telar/config.lua",
        try resolveDefaultPath(null, "", "/home/user", &buffer),
    );
    try std.testing.expectError(
        error.HomeDirectoryUnavailable,
        resolveDefaultPath(null, null, null, &buffer),
    );
}

test "Lua VM evaluates source under a bounded allocator" {
    var vm = try Vm.init(std.testing.io, .{
        .deadline_after_ns = default_callback_deadline_ns,
    });
    defer vm.deinit();
    try vm.evaluate("return 6 * 7", "@test.lua");
    var is_number: c_int = 0;
    try std.testing.expectEqual(
        @as(lua.lua_Integer, 42),
        lua.lua_tointegerx(vm.state, -1, &is_number),
    );
    try std.testing.expectEqual(@as(c_int, 1), is_number);
}

test "Lua VM interrupts an instruction loop" {
    var vm = try Vm.init(std.testing.io, .{
        .instructions = 10_000,
        .deadline_after_ns = std.time.ns_per_s,
    });
    defer vm.deinit();
    try std.testing.expectError(
        error.LuaRuntimeFailed,
        vm.evaluate("while true do end", "@loop.lua"),
    );
}

test "client config compiles theme, bindings, and callbacks" {
    const source =
        \\local telar = require("telar")
        \\local config = telar.config({ api_version = 2 })
        \\config.client = {
        \\  prefix = "ctrl+s",
        \\  theme = telar.theme({
        \\    base = "vesper",
        \\    colors = { accent = "#010203" },
        \\  }),
        \\  sidebar = { visible = false, renderer = "cells" },
        \\  pane_gaps = false,
        \\  input = { escape_timeout_ms = 40, sequence_timeout_ms = 750 },
        \\  keybindings = {
        \\    telar.bind({ "%" }, telar.action.split_pane({ direction = "horizontal" })),
        \\    telar.bind({ "g" }, function(ctx)
        \\      return telar.action.toggle_sidebar()
        \\    end),
        \\    telar.bind_global({ "ctrl+g" }, telar.action.detach()),
        \\    telar.bind({ "R" }, telar.action.resize_pane({ direction = "right" })),
        \\    telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
        \\  },
        \\}
        \\return config
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        7,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectEqual(@as(u16, 5), generation.snapshot.binding_count);
    try std.testing.expectEqual(@as(u16, 1), generation.callback_count);
    try std.testing.expect(!generation.snapshot.sidebar_visible);
    try std.testing.expect(!generation.snapshot.pane_gaps);
    try std.testing.expectEqual(kitty.SidebarRendering.cells, generation.snapshot.sidebar_rendering);
    try std.testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), generation.snapshot.input_escape_timeout_ns);
    try std.testing.expectEqual(@as(u64, 750 * std.time.ns_per_ms), generation.snapshot.input_sequence_timeout_ns);
    try std.testing.expectEqualDeep(
        core.ui.Color{ .rgb = .{ 1, 2, 3 } },
        generation.snapshot.theme.palette.accent,
    );
    try std.testing.expectEqualDeep(
        action_mod.Action{ .split_pane = .horizontal },
        generation.snapshot.bindings[0].action,
    );
    try std.testing.expectEqualDeep(
        action_mod.Action{ .lua_callback = .{ .generation = 7, .id = 0 } },
        generation.snapshot.bindings[1].action,
    );
    const ctrl_s = try keybind.parseKey("ctrl+s");
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.prefix);
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.bindings[0].keys[0]);
    try std.testing.expectEqualDeep(try keybind.parseKey("%"), generation.snapshot.bindings[0].keys[1]);
    try std.testing.expectEqual(@as(u8, 2), generation.snapshot.bindings[0].len);
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.bindings[1].keys[0]);
    try std.testing.expectEqualDeep(try keybind.parseKey("g"), generation.snapshot.bindings[1].keys[1]);
    try std.testing.expectEqualDeep(try keybind.parseKey("ctrl+g"), generation.snapshot.bindings[2].keys[0]);
    try std.testing.expectEqual(@as(u8, 1), generation.snapshot.bindings[2].len);
    try std.testing.expectEqual(action_mod.Action.detach, generation.snapshot.bindings[2].action);
    try std.testing.expectEqualDeep(
        action_mod.Action{ .resize_pane = .right },
        generation.snapshot.bindings[3].action,
    );
    try std.testing.expectEqual(
        action_mod.Action.toggle_pane_fullscreen,
        generation.snapshot.bindings[4].action,
    );
}

test "client config rejects an incompatible API version" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.IncompatibleConfigApi,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 1 }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "config.api_version is 1; this Telar accepts 2",
        diagnostic.message(),
    );
}

test "client config rejects non-boolean pane gaps" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, client = { pane_gaps = 0 } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "config.client.pane_gaps must be a boolean",
        diagnostic.message(),
    );
}

test "client config rejects invalid prefixes" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, client = { prefix = 'ctrl' } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "invalid config.client.prefix: MissingKey",
        diagnostic.message(),
    );
}

test "client config rejects invalid resize directions" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "r" }, telar.action.resize_pane({ direction = "diagonal" })),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            source,
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "resize-pane direction must be left, right, up, or down",
        diagnostic.message(),
    );
}

test "client config rejects unknown fields without replacing a generation" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, client = { typo = true } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings("unknown field config.client.typo", diagnostic.message());
}

test "Lua callback receives an immutable snapshot and returns bounded effects" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "s" }, function(ctx)
        \\      if ctx.tab_count ~= 3 or ctx.active_tab_index ~= 2 then error("bad context") end
        \\      return { telar.action.toggle_sidebar(), telar.action.focus_pane({ direction = "left" }) }
        \\    end),
        \\  } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        11,
        &diagnostic,
    );
    defer generation.deinit();
    const batch = try generation.invokeCallback(
        generation.snapshot.bindings[0].action.lua_callback,
        .{
            .sidebar_visible = true,
            .tab_count = 3,
            .active_tab_index = 1,
            .pane_count = 2,
            .focused_pane_id = 42,
        },
        &diagnostic,
    );
    try std.testing.expectEqual(@as(u8, 2), batch.len);
    try std.testing.expectEqualDeep(action_mod.Action.toggle_sidebar, batch.items[0]);
    try std.testing.expectEqualDeep(
        action_mod.Action{ .focus_pane = .left },
        batch.items[1],
    );
}

test "Lua expression returns semantic input instead of terminal bytes" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind_expr({ "h" }, function(ctx)
        \\      return telar.input.keys({ "left", "enter" })
        \\    end),
        \\  } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        3,
        &diagnostic,
    );
    defer generation.deinit();
    const decision = try generation.invokeExpression(
        generation.snapshot.bindings[0].action.lua_expr,
        .{
            .sidebar_visible = true,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 1,
        },
        &diagnostic,
    );
    try std.testing.expect(decision == .keys);
    try std.testing.expectEqual(@as(u8, 2), decision.keys.len);
    try std.testing.expectEqual(keybind.Key.Code.left, decision.keys.items[0].code);
    try std.testing.expectEqual(keybind.Key.Code.enter, decision.keys.items[1].code);
}

test "Lua callback cannot mutate its context" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "m" }, function(ctx)
        \\    ctx.tab_count = 99
        \\    return telar.action.toggle_sidebar()
        \\  end),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        4,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectError(
        error.LuaCallbackFailed,
        generation.invokeCallback(
            generation.snapshot.bindings[0].action.lua_callback,
            .{
                .sidebar_visible = true,
                .tab_count = 1,
                .active_tab_index = 0,
                .pane_count = 1,
                .focused_pane_id = 1,
            },
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "immutable") != null);
}

test "Lua callback execution is interrupted by its instruction budget" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "l" }, function(ctx) while true do end end),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectError(
        error.LuaCallbackFailed,
        generation.invokeCallback(
            generation.snapshot.bindings[0].action.lua_callback,
            .{
                .sidebar_visible = true,
                .tab_count = 1,
                .active_tab_index = 0,
                .pane_count = 1,
                .focused_pane_id = 1,
            },
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "budget exceeded") != null);
}

test "configuration environment excludes ambient authority" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { sidebar = { visible = io == nil and os == nil and debug == nil } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.sidebar_visible);
}

test "runtime config compiles bounded graphics and ProxyTLS values" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { history = { path = 'state/history.db' }, graphics = { pane_mib = 32, global_mib = 128 }, proxy = { enabled = true, ca_dir = 'state/proxy' } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectEqual(
        @as(usize, 32 * 1024 * 1024),
        generation.snapshot.runtime.graphics_pane_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 128 * 1024 * 1024),
        generation.snapshot.runtime.graphics_global_bytes,
    );
    try std.testing.expectEqualStrings(
        "state/history.db",
        generation.snapshot.runtime.historyPath().?,
    );
    try std.testing.expect(generation.snapshot.runtime.proxy_enabled);
    try std.testing.expectEqualStrings(
        "state/proxy",
        generation.snapshot.runtime.proxyCaDir().?,
    );
}

test "runtime ProxyTLS config rejects live Lua middleware closures" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, runtime = { proxy = { enabled = true, middleware = function() end } } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "unknown field config.runtime.proxy.middleware",
        diagnostic.message(),
    );
}

test "profile overlays base config before CLI locks are applied" {
    const source =
        \\return {
        \\  api_version = 2,
        \\  client = {
        \\    prefix = "ctrl+b",
        \\    sidebar = { visible = true, renderer = "automatic" },
        \\    keybindings = {
        \\      require("telar").bind_expr({ "f" }, function(ctx)
        \\        return require("telar").input.forward()
        \\      end),
        \\    },
        \\  },
        \\  runtime = { graphics = { pane_mib = 64, global_mib = 256 } },
        \\  profiles = {
        \\    remote = {
        \\      client = {
        \\        prefix = "ctrl+s",
        \\        sidebar = { visible = false, renderer = "cells" },
        \\      },
        \\      runtime = { graphics = { pane_mib = 16, global_mib = 64 } },
        \\    },
        \\  },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSourceProfile(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        1,
        "remote",
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expect(!generation.snapshot.sidebar_visible);
    try std.testing.expectEqual(kitty.SidebarRendering.cells, generation.snapshot.sidebar_rendering);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), generation.snapshot.runtime.graphics_pane_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), generation.snapshot.runtime.graphics_global_bytes);
    const binding = generation.snapshot.bindings[0];
    try std.testing.expectEqualDeep(try keybind.parseKey("ctrl+s"), binding.keys[0]);
    try std.testing.expectEqualDeep(try keybind.parseKey("f"), binding.keys[1]);
    const decision = try generation.invokeExpression(
        binding.action.lua_expr,
        .{
            .sidebar_visible = false,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 1,
        },
        &diagnostic,
    );
    try std.testing.expect(decision == .forward_binding);
    try std.testing.expectEqual(@as(u8, 2), decision.forward_binding.len);
    try std.testing.expectEqualDeep(try keybind.parseKey("ctrl+s"), decision.forward_binding.items[0]);
    try std.testing.expectEqualDeep(try keybind.parseKey("f"), decision.forward_binding.items[1]);
}

test "selected profile must exist" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.UnknownProfile,
        Generation.loadSourceProfile(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, profiles = {} }",
            "@config.lua",
            1,
            "missing",
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings("profile 'missing' is not defined", diagnostic.message());
}

test "unselected profiles are still validated deeply" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, profiles = { broken = { client = { typo = true } } } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings("unknown field config.client.typo", diagnostic.message());
}

test "local modules are contained and participate in reload fingerprints" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    {
        var module = try temp.dir.createFile(io, "settings.lua", .{});
        defer module.close(io);
        try module.writeStreamingAll(io, "return { renderer = 'cells' }");
    }
    {
        var config = try temp.dir.createFile(io, "config.lua", .{});
        defer config.close(io);
        try config.writeStreamingAll(
            io,
            "local s = require('settings'); return { api_version = 2, client = { sidebar = s } }",
        );
    }
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(
        &config_path_buffer,
        "{s}/config.lua",
        .{directory_buffer[0..directory_len]},
    );
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadFile(
        std.testing.allocator,
        io,
        config_path,
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectEqual(@as(u8, 1), generation.dependency_count);
    try std.testing.expectEqual(kitty.SidebarRendering.cells, generation.snapshot.sidebar_rendering);
    const before = generation.watchFingerprint(io, config_path);
    {
        var module = try temp.dir.createFile(io, "settings.lua", .{ .truncate = true });
        defer module.close(io);
        try module.writeStreamingAll(io, "return { renderer = 'automatic', visible = false }");
    }
    try std.testing.expect(before != generation.watchFingerprint(io, config_path));
}

test "local require rejects a symlink escaping the config directory" {
    const io = std.testing.io;
    var config_temp = std.testing.tmpDir(.{});
    defer config_temp.cleanup();
    var outside_temp = std.testing.tmpDir(.{});
    defer outside_temp.cleanup();
    {
        var outside = try outside_temp.dir.createFile(io, "outside.lua", .{});
        defer outside.close(io);
        try outside.writeStreamingAll(io, "return {}");
    }
    var outside_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const outside_directory_len = try outside_temp.dir.realPath(io, &outside_directory_buffer);
    var outside_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path = try std.fmt.bufPrint(
        &outside_path_buffer,
        "{s}/outside.lua",
        .{outside_directory_buffer[0..outside_directory_len]},
    );
    try config_temp.dir.symLink(io, outside_path, "escape.lua", .{});
    {
        var config = try config_temp.dir.createFile(io, "config.lua", .{});
        defer config.close(io);
        try config.writeStreamingAll(
            io,
            "require('escape'); return { api_version = 2 }",
        );
    }
    var config_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_directory_len = try config_temp.dir.realPath(io, &config_directory_buffer);
    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(
        &config_path_buffer,
        "{s}/config.lua",
        .{config_directory_buffer[0..config_directory_len]},
    );
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.LuaRuntimeFailed,
        Generation.loadFile(
            std.testing.allocator,
            io,
            config_path,
            1,
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "escapes") != null);
}
