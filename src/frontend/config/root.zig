//! Client-owned Lua configuration and callback VM.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const input = @import("../input/root.zig");
const action_mod = input.action;
const bars = @import("../bars/root.zig");
const config_model = @import("model.zig");
const default_bindings = @import("default_bindings.zig");
const keybind = input.keybind;
const kitty = @import("../graphics/root.zig").kitty;
const icons = @import("../ui/root.zig").icons;
const theme_mod = @import("../ui/root.zig").theme;

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
pub const max_proxy_passthrough_hosts = config_model.max_proxy_passthrough_hosts;
pub const max_proxy_passthrough_host_bytes = config_model.max_proxy_passthrough_host_bytes;
pub const max_proxy_passthrough_bytes = config_model.max_proxy_passthrough_bytes;
pub const max_agent_description_command_args = config_model.max_agent_description_command_args;
pub const max_agent_description_command_bytes = config_model.max_agent_description_command_bytes;
pub const max_bar_callbacks = config_model.max_bar_callbacks;
pub const min_agent_description_timeout_ms = config_model.min_agent_description_timeout_ms;
pub const max_agent_description_timeout_ms = config_model.max_agent_description_timeout_ms;
pub const default_binding_count = default_bindings.count;
pub const default_binding_max_keys = default_bindings.max_keys;
pub const DefaultBinding = default_bindings.Binding;
pub const loadDefaultBindings = default_bindings.load;
pub const resolveBindings = default_bindings.resolve;
pub const validateKeymap = default_bindings.validate;

pub const ConfiguredBinding = config_model.ConfiguredBinding;
pub const Diagnostic = config_model.Diagnostic;
pub const Snapshot = config_model.Snapshot;
pub const PluginSpec = config_model.PluginSpec;
pub const RuntimeSnapshot = config_model.RuntimeSnapshot;
pub const AgentDescriptionCommand = config_model.AgentDescriptionCommand;
pub const SoundConfig = config_model.SoundConfig;
pub const BarCallbackContext = config_model.BarCallbackContext;
pub const BarTime = config_model.BarTime;
pub const BarMetrics = config_model.BarMetrics;
pub const BarInvocation = config_model.BarInvocation;

const Callback = struct {
    registry_ref: c_int,
    expression: bool,
    trigger: [max_binding_keys]keybind.Key = @splat(.plain(.escape)),
    trigger_len: u8 = 0,
};

const BarCallback = struct {
    registry_ref: c_int,
};

pub const CallbackContext = config_model.CallbackContext;
pub const EffectBatch = config_model.EffectBatch;
pub const InputKeys = config_model.InputKeys;
pub const InputPaste = config_model.InputPaste;
pub const InputDecision = config_model.InputDecision;
pub const Limits = config_model.Limits;

pub const Meter = struct {
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
    bar_callbacks: [max_bar_callbacks]BarCallback = undefined,
    bar_callback_count: u8 = 0,
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

    pub fn invokeBar(generation: *Generation, invocation: BarInvocation, diagnostic: *Diagnostic) !bars.Content {
        const reference = invocation.reference;
        if (reference.generation != generation.number or reference.id >= generation.bar_callback_count) {
            diagnostic.set("bar callback belongs to an obsolete configuration generation", .{});
            return error.StaleBarCallback;
        }

        const state = generation.vm.state;
        lua.lua_settop(state, 0);
        defer lua.lua_settop(state, 0);
        generation.vm.resetBudget(default_callback_instruction_limit, default_callback_deadline_ns);
        _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, generation.bar_callbacks[reference.id].registry_ref);
        pushReadonlyBarContext(state, invocation.context);
        if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
            diagnostic.set("Lua bar callback failed: {s}", .{generation.vm.errorMessage()});
            return error.LuaBarCallbackFailed;
        }

        return parseBarContent(state, -1, diagnostic);
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
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "graphics", "history", "proxy", "agent_descriptions", "agents", "session" },
            "config.runtime",
            diagnostic,
        );
        _ = lua.lua_getfield(state, absolute, "session");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseSession(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "agents");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseAgentManifests(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "history");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseHistory(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "proxy");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseProxy(-1, diagnostic);
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "agent_descriptions");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseAgentDescriptions(-1, diagnostic);
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

    /// Parses `config.runtime.agents`, an array of manifests that add agents
    /// or extend the built-in `claude` and `codex` phrase lists.
    fn parseAgentManifests(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.agents must be an array", .{});
            return error.InvalidConfig;
        }

        const count = lua.lua_rawlen(state, absolute);
        try ensureArrayOnly(state, absolute, count, "config.runtime.agents", diagnostic);
        const table = &generation.snapshot.runtime.agent_manifests;
        for (1..count + 1) |position| {
            _ = lua.lua_rawgeti(state, absolute, @intCast(position));
            defer pop(state, 1);
            if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
                diagnostic.set("config.runtime.agents[{d}] must be a table", .{position});
                return error.InvalidConfig;
            }

            const entry = lua.lua_absindex(state, -1);
            try ensureOnlyFields(
                state,
                entry,
                &.{ "name", "process_names", "process_paths", "brand", "identity", "working", "blocked", "ready_prompt" },
                "config.runtime.agents[]",
                diagnostic,
            );

            _ = lua.lua_getfield(state, entry, "name");
            var name_len: usize = 0;
            var name: []const u8 = "";
            if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
                if (lua.lua_tolstring(state, -1, &name_len)) |raw| name = raw[0..name_len];
            }
            const manifest = table.add(name) catch |err| {
                pop(state, 1);
                diagnostic.set("config.runtime.agents[{d}].name {s}", .{ position, switch (err) {
                    error.InvalidName => "must be lowercase letters, digits, '-', '_' or '.' (1..32 bytes)",
                    error.DuplicateName => "is already defined",
                    error.TooManyAgents => "exceeds the agent limit",
                } });
                return error.InvalidConfig;
            };
            pop(state, 1);

            try parseManifestList(state, entry, "process_names", &manifest.process_names, position, diagnostic);
            try parseManifestList(state, entry, "process_paths", &manifest.process_paths, position, diagnostic);
            try parseManifestList(state, entry, "brand", &manifest.brand, position, diagnostic);
            try parseManifestList(state, entry, "identity", &manifest.identity, position, diagnostic);
            try parseManifestList(state, entry, "working", &manifest.working, position, diagnostic);
            try parseManifestList(state, entry, "blocked", &manifest.blocked, position, diagnostic);
            try parseManifestList(state, entry, "ready_prompt", &manifest.ready_prompt, position, diagnostic);
        }
    }

    fn parseAgentDescriptions(
        generation: *Generation,
        index: c_int,
        diagnostic: *Diagnostic,
    ) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.agent_descriptions must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "command", "timeout_ms" },
            "config.runtime.agent_descriptions",
            diagnostic,
        );

        _ = lua.lua_getfield(state, absolute, "command");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.agent_descriptions.command must be an array", .{});
            return error.InvalidConfig;
        }
        const command_table = lua.lua_absindex(state, -1);
        const count = lua.lua_rawlen(state, command_table);
        if (count == 0 or count > max_agent_description_command_args) {
            diagnostic.set(
                "config.runtime.agent_descriptions.command must contain 1..{d} arguments",
                .{max_agent_description_command_args},
            );
            return error.InvalidConfig;
        }
        try ensureArrayOnly(
            state,
            command_table,
            count,
            "config.runtime.agent_descriptions.command",
            diagnostic,
        );

        var command: AgentDescriptionCommand = .{};
        for (0..count) |argument_index| {
            _ = lua.lua_geti(state, command_table, @intCast(argument_index + 1));
            defer pop(state, 1);
            const argument = string(state, -1) orelse {
                diagnostic.set(
                    "config.runtime.agent_descriptions.command[{d}] must be a string",
                    .{argument_index + 1},
                );
                return error.InvalidConfig;
            };
            if ((argument_index == 0 and argument.len == 0) or
                argument.len > std.math.maxInt(u16) or
                argument.len > max_agent_description_command_bytes - command.byte_len or
                std.mem.indexOfScalar(u8, argument, 0) != null)
            {
                diagnostic.set(
                    "config.runtime.agent_descriptions.command exceeds its {d}-byte limit",
                    .{max_agent_description_command_bytes},
                );
                return error.InvalidConfig;
            }
            command.offsets[argument_index] = command.byte_len;
            command.lengths[argument_index] = @intCast(argument.len);
            @memcpy(command.bytes[command.byte_len..][0..argument.len], argument);
            command.byte_len += @intCast(argument.len);
        }
        command.argument_count = @intCast(count);

        _ = lua.lua_getfield(state, absolute, "timeout_ms");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const timeout_ms = integer(state, -1) orelse {
                diagnostic.set("config.runtime.agent_descriptions.timeout_ms must be an integer", .{});
                return error.InvalidConfig;
            };
            if (timeout_ms < min_agent_description_timeout_ms or
                timeout_ms > max_agent_description_timeout_ms)
            {
                diagnostic.set(
                    "config.runtime.agent_descriptions.timeout_ms must be in {d}..{d}",
                    .{ min_agent_description_timeout_ms, max_agent_description_timeout_ms },
                );
                return error.InvalidConfig;
            }
            command.timeout_ms = @intCast(timeout_ms);
        }
        generation.snapshot.runtime.agent_descriptions = command;
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
            &.{ "enabled", "ca_dir", "passthrough_hosts" },
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
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const path = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.runtime.proxy.ca_dir must be a string", .{});
                return error.InvalidConfig;
            };
            if (path.len == 0 or path.len > max_proxy_path_bytes or
                std.mem.indexOfScalar(u8, path, 0) != null)
            {
                pop(state, 1);
                diagnostic.set("config.runtime.proxy.ca_dir is invalid", .{});
                return error.InvalidConfig;
            }
            @memcpy(generation.snapshot.runtime.proxy_ca_dir_bytes[0..path.len], path);
            generation.snapshot.runtime.proxy_ca_dir_len = @intCast(path.len);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "passthrough_hosts");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.proxy.passthrough_hosts must be an array", .{});
            return error.InvalidConfig;
        }
        const hosts = lua.lua_absindex(state, -1);
        const count = lua.lua_rawlen(state, hosts);
        if (count > max_proxy_passthrough_hosts) {
            diagnostic.set(
                "config.runtime.proxy.passthrough_hosts exceeds {d} entries",
                .{max_proxy_passthrough_hosts},
            );
            return error.InvalidConfig;
        }
        try ensureArrayOnly(
            state,
            hosts,
            count,
            "config.runtime.proxy.passthrough_hosts",
            diagnostic,
        );
        for (0..count) |host_index| {
            _ = lua.lua_geti(state, hosts, @intCast(host_index + 1));
            defer pop(state, 1);
            const host = string(state, -1) orelse {
                diagnostic.set(
                    "config.runtime.proxy.passthrough_hosts[{d}] must be a hostname",
                    .{host_index + 1},
                );
                return error.InvalidConfig;
            };
            if (!validProxyHostname(host)) {
                diagnostic.set(
                    "config.runtime.proxy.passthrough_hosts[{d}] is not a valid hostname",
                    .{host_index + 1},
                );
                return error.InvalidConfig;
            }
            generation.snapshot.runtime.proxy_passthrough_hosts.append(host) catch {
                diagnostic.set(
                    "config.runtime.proxy.passthrough_hosts exceeds its {d}-byte budget",
                    .{max_proxy_passthrough_bytes},
                );
                return error.InvalidConfig;
            };
        }
        generation.snapshot.runtime.proxy_passthrough_hosts.sortAndDeduplicate();
    }

    fn parseSession(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.session must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, absolute, &.{ "persist", "path", "resume_agents" }, "config.runtime.session", diagnostic);

        _ = lua.lua_getfield(state, absolute, "resume_agents");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.runtime.session.resume_agents must be a boolean", .{});
                return error.InvalidConfig;
            }
            generation.snapshot.runtime.session_resume_agents = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "persist");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.runtime.session.persist must be a boolean", .{});
                return error.InvalidConfig;
            }
            generation.snapshot.runtime.session_persist = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "path");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
        var len: usize = 0;
        var path: []const u8 = "";
        if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
            if (lua.lua_tolstring(state, -1, &len)) |raw| path = raw[0..len];
        }
        if (path.len == 0 or path.len > max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
            diagnostic.set("config.runtime.session.path is invalid", .{});
            return error.InvalidConfig;
        }
        @memcpy(generation.snapshot.runtime.session_path_bytes[0..path.len], path);
        generation.snapshot.runtime.session_path_len = @intCast(path.len);
    }

    /// Parses `client.appearance`: the themes adopted when the host terminal
    /// reports a light or dark background.
    fn parseAppearance(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.appearance must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, absolute, &.{ "light", "dark" }, "config.client.appearance", diagnostic);

        _ = lua.lua_getfield(state, absolute, "light");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            generation.snapshot.theme_light = try parseTheme(state, -1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "dark");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            generation.snapshot.theme_dark = try parseTheme(state, -1, diagnostic);
        pop(state, 1);
    }

    fn parseNotifications(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.notifications must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(state, absolute, &.{"delivery"}, "config.client.notifications", diagnostic);

        _ = lua.lua_getfield(state, absolute, "delivery");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
        const value = string(state, -1) orelse {
            diagnostic.set("config.client.notifications.delivery must be a string", .{});
            return error.InvalidConfig;
        };
        generation.snapshot.notification_delivery = config_model.NotificationDelivery.parse(value) orelse {
            diagnostic.set("config.client.notifications.delivery must be telar, terminal or system", .{});
            return error.InvalidConfig;
        };
    }

    fn parseHistory(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.history must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "path", "secrets_filter", "command_filters", "cwd_filters", "output" },
            "config.runtime.history",
            diagnostic,
        );

        _ = lua.lua_getfield(state, absolute, "output");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const mode = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.runtime.history.output must be off or bounded", .{});
                return error.InvalidConfig;
            };
            if (std.mem.eql(u8, mode, "bounded")) {
                generation.snapshot.runtime.history_output_capture = true;
            } else if (std.mem.eql(u8, mode, "off")) {
                generation.snapshot.runtime.history_output_capture = false;
            } else {
                pop(state, 1);
                diagnostic.set("config.runtime.history.output must be off or bounded", .{});
                return error.InvalidConfig;
            }
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "path");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const path = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.runtime.history.path must be a string", .{});
                return error.InvalidConfig;
            };
            if (path.len == 0 or path.len > max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
                pop(state, 1);
                diagnostic.set("config.runtime.history.path is invalid", .{});
                return error.InvalidConfig;
            }

            @memcpy(generation.snapshot.runtime.history_path_bytes[0..path.len], path);
            generation.snapshot.runtime.history_path_len = @intCast(path.len);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "secrets_filter");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.runtime.history.secrets_filter must be a boolean", .{});
                return error.InvalidConfig;
            }

            generation.snapshot.runtime.history_filters.secrets = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        try generation.parseHistoryPatterns(absolute, "command_filters", diagnostic);
        try generation.parseHistoryPatterns(absolute, "cwd_filters", diagnostic);
    }

    /// Parses one `config.runtime.history` pattern array into the bounded
    /// record-time filter list with the same name.
    fn parseHistoryPatterns(generation: *Generation, absolute: c_int, comptime name: [:0]const u8, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        _ = lua.lua_getfield(state, absolute, name.ptr);
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
            return;
        }
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("config.runtime.history.{s} must be an array of strings", .{name});
            return error.InvalidConfig;
        }

        const table = lua.lua_absindex(state, -1);
        const count = lua.lua_rawlen(state, table);
        try ensureArrayOnly(state, table, count, "config.runtime.history." ++ name, diagnostic);
        const list = if (comptime std.mem.eql(u8, name, "command_filters"))
            &generation.snapshot.runtime.history_filters.commands
        else
            &generation.snapshot.runtime.history_filters.cwds;
        for (1..count + 1) |item| {
            _ = lua.lua_rawgeti(state, table, @intCast(item));
            defer pop(state, 1);
            const pattern = string(state, -1) orelse {
                diagnostic.set("config.runtime.history.{s}[{d}] must be a string", .{ name, item });
                return error.InvalidConfig;
            };
            list.add(pattern) catch {
                diagnostic.set("config.runtime.history.{s}[{d}] is empty, too long or exceeds the pattern limit", .{ name, item });
                return error.InvalidConfig;
            };
        }
    }

    fn parseClientHistory(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.history must be a table", .{});
            return error.InvalidConfig;
        }

        try ensureOnlyFields(state, absolute, &.{ "show_agent_commands", "enter", "match" }, "config.client.history", diagnostic);

        _ = lua.lua_getfield(state, absolute, "match");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const mode = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
                return error.InvalidConfig;
            };
            if (std.mem.eql(u8, mode, "fts")) {
                generation.snapshot.history_match_fts = true;
            } else if (std.mem.eql(u8, mode, "fuzzy")) {
                generation.snapshot.history_match_fts = false;
            } else {
                pop(state, 1);
                diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
                return error.InvalidConfig;
            }
        }
        pop(state, 1);
        _ = lua.lua_getfield(state, absolute, "show_agent_commands");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("config.client.history.show_agent_commands must be a boolean", .{});
                return error.InvalidConfig;
            }

            generation.snapshot.history_show_agent_commands = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "enter");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
            return;
        }
        const value = string(state, -1) orelse {
            diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        };
        if (std.mem.eql(u8, value, "run")) {
            generation.snapshot.history_enter_runs = true;
        } else if (std.mem.eql(u8, value, "paste")) {
            generation.snapshot.history_enter_runs = false;
        } else {
            diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        }
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
            &.{ "prefix", "theme", "icons", "sidebar", "pane_gaps", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "history" },
            "config.client",
            diagnostic,
        );

        _ = lua.lua_getfield(state, absolute, "prefix");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parsePrefix(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "history");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseClientHistory(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "theme");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            generation.snapshot.theme = try parseTheme(state, -1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "icons");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            const value = string(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("config.client.icons must be a string", .{});
                return error.InvalidConfig;
            };
            generation.snapshot.icon_theme = icons.Theme.parse(value) catch {
                diagnostic.set("unknown config.client.icons: {s}", .{value});
                pop(state, 1);
                return error.InvalidConfig;
            };
        }
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

        _ = lua.lua_getfield(state, absolute, "window_title");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TSTRING) {
                pop(state, 1);
                diagnostic.set("config.client.window_title must be a string", .{});
                return error.InvalidConfig;
            }

            var len: usize = 0;
            const template: []const u8 = if (lua.lua_tolstring(state, -1, &len)) |raw| raw[0..len] else "";
            if (template.len > config_model.max_window_title_bytes or !std.unicode.utf8ValidateSlice(template) or hasControlBytes(template)) {
                pop(state, 1);
                diagnostic.set("config.client.window_title must be printable UTF-8 of at most {d} bytes", .{config_model.max_window_title_bytes});
                return error.InvalidConfig;
            }

            @memcpy(generation.snapshot.window_title_bytes[0..template.len], template);
            generation.snapshot.window_title_len = @intCast(template.len);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "sound");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseSound(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "notifications");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseNotifications(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "appearance");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseAppearance(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "input");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseInputOptions(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "keybindings");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL)
            try generation.parseBindings(-1, diagnostic);
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "bars");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            try generation.parseBars(-1, diagnostic);
        }
        pop(state, 1);
    }

    fn parseBars(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.bars must be a table", .{});
            return error.InvalidConfig;
        }

        try ensureOnlyFields(state, absolute, &.{ "bottom", "top" }, "config.client.bars", diagnostic);

        _ = lua.lua_getfield(state, absolute, "bottom");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            try generation.parseBottomBar(-1, diagnostic);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "top");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            try generation.parseTopBar(-1, diagnostic);
        }
        pop(state, 1);
    }

    fn parseBottomBar(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.bars.bottom must be a table", .{});
            return error.InvalidConfig;
        }

        try ensureOnlyFields(state, absolute, &.{ "left", "center", "right" }, "config.client.bars.bottom", diagnostic);
        var parsed: [3]bars.Source = .{ .empty, .empty, .empty };
        inline for (.{ "left", "center", "right" }, 0..) |field, source_index| {
            _ = lua.lua_getfield(state, absolute, field);
            if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
                parsed[source_index] = try generation.parseBarSource(-1, diagnostic);
            }
            pop(state, 1);
        }

        var tab_count: u8 = 0;
        for (parsed) |source| {
            tab_count += @intFromBool(source == .tabs);
        }
        if (tab_count != 1) {
            diagnostic.set("config.client.bars.bottom must contain exactly one telar.bar.tabs()", .{});
            return error.InvalidConfig;
        }

        generation.snapshot.bars.bottom = parsed;
    }

    fn parseTopBar(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.bars.top must be a table", .{});
            return error.InvalidConfig;
        }

        try ensureOnlyFields(state, absolute, &.{"right"}, "config.client.bars.top", diagnostic);
        _ = lua.lua_getfield(state, absolute, "right");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
            generation.snapshot.bars.top_right = .empty;
            return;
        }

        const source = try generation.parseBarSource(-1, diagnostic);
        if (source == .tabs) {
            diagnostic.set("config.client.bars.top.right cannot contain tabs", .{});
            return error.InvalidConfig;
        }

        generation.snapshot.bars.top_right = source;
    }

    fn parseBarSource(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !bars.Source {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("bar position must contain a telar.bar value", .{});
            return error.InvalidConfig;
        }

        _ = lua.lua_getfield(state, absolute, "bar_kind");
        const kind = string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("bar position must contain a telar.bar value", .{});
            return error.InvalidConfig;
        };
        pop(state, 1);

        if (std.mem.eql(u8, kind, "tabs")) {
            try ensureOnlyFields(state, absolute, &.{"bar_kind"}, "bar tabs", diagnostic);
            return .tabs;
        }
        if (std.mem.eql(u8, kind, "metrics")) {
            try ensureOnlyFields(state, absolute, &.{"bar_kind"}, "bar metrics", diagnostic);
            return .metrics;
        }
        if (std.mem.eql(u8, kind, "static")) {
            try ensureOnlyFields(state, absolute, &.{ "bar_kind", "value" }, "bar static block", diagnostic);
            _ = lua.lua_getfield(state, absolute, "value");
            defer pop(state, 1);
            return .{ .static = try parseBarContent(state, -1, diagnostic) };
        }
        if (std.mem.eql(u8, kind, "dynamic")) {
            try ensureOnlyFields(state, absolute, &.{ "bar_kind", "every_ms", "render" }, "bar dynamic block", diagnostic);
            const interval_ns = try parseBarInterval(state, absolute, diagnostic);
            _ = lua.lua_getfield(state, absolute, "render");
            defer pop(state, 1);
            const callback = try generation.registerBarCallback(-1, diagnostic);
            return .{ .dynamic = .{ .callback = callback, .interval_ns = interval_ns } };
        }
        if (std.mem.eql(u8, kind, "command")) {
            return generation.parseBarCommand(absolute, diagnostic);
        }

        diagnostic.set("unknown bar value '{s}'", .{kind});
        return error.InvalidConfig;
    }

    fn parseBarCommand(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !bars.Source {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "bar_kind", "command", "every_ms", "timeout_ms", "render" },
            "bar command block",
            diagnostic,
        );

        const interval_ns = try parseBarInterval(state, absolute, diagnostic);
        _ = lua.lua_getfield(state, absolute, "timeout_ms");
        const timeout_value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
            2_000
        else
            integer(state, -1) orelse {
                pop(state, 1);
                diagnostic.set("bar command timeout_ms must be an integer", .{});
                return error.InvalidConfig;
            };
        pop(state, 1);
        if (timeout_value < bars.min_command_timeout_ms or timeout_value > bars.max_command_timeout_ms) {
            diagnostic.set(
                "bar command timeout_ms must be in {d}..{d}",
                .{ bars.min_command_timeout_ms, bars.max_command_timeout_ms },
            );
            return error.InvalidConfig;
        }

        var command: bars.Command = .{
            .generation = generation.number,
            .interval_ns = interval_ns,
            .timeout_ms = @intCast(timeout_value),
        };
        _ = lua.lua_getfield(state, absolute, "command");
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            pop(state, 1);
            diagnostic.set("bar command must be an array", .{});
            return error.InvalidConfig;
        }
        const command_table = lua.lua_absindex(state, -1);
        const count = lua.lua_rawlen(state, command_table);
        if (count == 0 or count > bars.max_command_args) {
            pop(state, 1);
            diagnostic.set("bar command must contain 1..{d} arguments", .{bars.max_command_args});
            return error.InvalidConfig;
        }
        try ensureArrayOnly(state, command_table, count, "bar command", diagnostic);
        for (0..count) |argument_index| {
            _ = lua.lua_geti(state, command_table, @intCast(argument_index + 1));
            const argument_value = string(state, -1) orelse {
                pop(state, 2);
                diagnostic.set("bar command argument {d} must be a string", .{argument_index + 1});
                return error.InvalidConfig;
            };
            command.appendArgument(argument_value) catch |err| {
                pop(state, 2);
                diagnostic.set("invalid bar command: {s}", .{@errorName(err)});
                return error.InvalidConfig;
            };
            pop(state, 1);
        }
        pop(state, 1);

        _ = lua.lua_getfield(state, absolute, "render");
        defer pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            command.render = try generation.registerBarCallback(-1, diagnostic);
        }

        return .{ .command = command };
    }

    fn registerBarCallback(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !bars.CallbackRef {
        const state = generation.vm.state;
        if (lua.lua_type(state, index) != lua.LUA_TFUNCTION) {
            diagnostic.set("bar render must be a Lua function", .{});
            return error.InvalidConfig;
        }
        if (generation.bar_callback_count == max_bar_callbacks) {
            diagnostic.set("configuration exceeds {d} bar callbacks", .{max_bar_callbacks});
            return error.InvalidConfig;
        }

        lua.lua_pushvalue(state, index);
        const registry_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        const id = generation.bar_callback_count;
        generation.bar_callbacks[id] = .{ .registry_ref = registry_ref };
        generation.bar_callback_count += 1;
        return .{ .generation = generation.number, .id = id };
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

    fn parseSound(generation: *Generation, index: c_int, diagnostic: *Diagnostic) !void {
        const state = generation.vm.state;
        const absolute = lua.lua_absindex(state, index);
        if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
            diagnostic.set("config.client.sound must be a table", .{});
            return error.InvalidConfig;
        }
        try ensureOnlyFields(
            state,
            absolute,
            &.{ "enabled", "ready", "needs_input" },
            "config.client.sound",
            diagnostic,
        );
        inline for (.{ "enabled", "ready", "needs_input" }) |field| {
            _ = lua.lua_getfield(state, absolute, field);
            if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
                if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                    pop(state, 1);
                    diagnostic.set("config.client.sound.{s} must be a boolean", .{field});
                    return error.InvalidConfig;
                }
                @field(generation.snapshot.sound, field) = lua.lua_toboolean(state, -1) != 0;
            }
            pop(state, 1);
        }
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
            std.mem.eql(u8, kind, "navigate-pane") or
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
            else if (std.mem.eql(u8, kind, "navigate-pane"))
                .{ .navigate_pane = parsed_direction }
            else
                .{ .resize_pane = parsed_direction };
        }
        if (std.mem.eql(u8, kind, "resize-sidebar")) {
            try ensureOnlyFields(state, absolute, &.{ "kind", "direction" }, "action", diagnostic);
            const direction = try requiredStringField(state, absolute, "direction", diagnostic);
            if (std.mem.eql(u8, direction, "left")) {
                return .{ .resize_sidebar = .left };
            }
            if (std.mem.eql(u8, direction, "right")) {
                return .{ .resize_sidebar = .right };
            }

            diagnostic.set("resize-sidebar direction must be left or right", .{});
            return error.InvalidConfig;
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
        if (std.mem.eql(u8, kind, "command-tab")) {
            try ensureOnlyFields(
                state,
                absolute,
                &.{ "kind", "command", "label" },
                "action",
                diagnostic,
            );
            _ = lua.lua_getfield(state, absolute, "command");
            defer pop(state, 1);
            if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
                diagnostic.set("command-tab action needs a command array", .{});
                return error.InvalidConfig;
            }
            const command_table = lua.lua_absindex(state, -1);
            const count = lua.lua_rawlen(state, command_table);
            if (count == 0 or count > action_mod.CommandTab.max_arguments) {
                diagnostic.set("command-tab command must contain 1..{d} arguments", .{action_mod.CommandTab.max_arguments});
                return error.InvalidConfig;
            }
            try ensureArrayOnly(state, command_table, count, "command-tab command", diagnostic);
            var argument_storage: [action_mod.CommandTab.max_arguments][]const u8 = undefined;
            for (1..count + 1) |item| {
                _ = lua.lua_rawgeti(state, command_table, @intCast(item));
                defer pop(state, 1);
                var len: usize = 0;
                var text: []const u8 = "";
                if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
                    if (lua.lua_tolstring(state, -1, &len)) |raw| text = raw[0..len];
                }
                if (text.len == 0) {
                    diagnostic.set("command-tab command[{d}] must be a string", .{item});
                    return error.InvalidConfig;
                }
                argument_storage[item - 1] = text;
            }
            var label: []const u8 = "";
            _ = lua.lua_getfield(state, absolute, "label");
            if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
                var len: usize = 0;
                if (lua.lua_tolstring(state, -1, &len)) |raw| label = raw[0..len];
            }
            defer pop(state, 1);
            return .{ .command_tab = action_mod.CommandTab.init(argument_storage[0..count], label) catch {
                diagnostic.set("command-tab command or label is invalid or too long", .{});
                return error.InvalidConfig;
            } };
        }
        if (std.mem.eql(u8, kind, "notification")) {
            try ensureOnlyFields(
                state,
                absolute,
                &.{
                    "kind",
                    "title",
                    "body",
                    "level",
                    "duration_ms",
                    "pane_id",
                    "tab_id",
                    "workspace_id",
                },
                "action",
                diagnostic,
            );
            const title = try requiredStringField(state, absolute, "title", diagnostic);
            const body = try optionalStringField(state, absolute, "body", "", diagnostic);
            const level_name = try optionalStringField(state, absolute, "level", "info", diagnostic);
            const level: core.schema.NotificationLevel = if (std.mem.eql(u8, level_name, "info"))
                .info
            else if (std.mem.eql(u8, level_name, "success"))
                .success
            else if (std.mem.eql(u8, level_name, "warning"))
                .warning
            else if (std.mem.eql(u8, level_name, "failure"))
                .failure
            else {
                diagnostic.set("notification level must be info, success, warning, or failure", .{});
                return error.InvalidConfig;
            };
            const duration = try optionalIntegerField(
                state,
                absolute,
                "duration_ms",
                core.schema.default_notification_duration_ms,
                diagnostic,
            );
            if (duration < core.schema.min_notification_duration_ms or
                duration > core.schema.max_notification_duration_ms)
            {
                diagnostic.set(
                    "notification duration_ms must be in {d}..{d}",
                    .{
                        core.schema.min_notification_duration_ms,
                        core.schema.max_notification_duration_ms,
                    },
                );
                return error.InvalidConfig;
            }

            var target: core.schema.NotificationTarget = .none;
            var target_count: u8 = 0;
            if (try optionalPositiveId(state, absolute, "pane_id", diagnostic)) |raw| {
                target = .{ .pane = core.schema.id.pane(raw) catch {
                    diagnostic.set("notification pane_id is invalid", .{});
                    return error.InvalidConfig;
                } };
                target_count += 1;
            }
            if (try optionalPositiveId(state, absolute, "tab_id", diagnostic)) |raw| {
                target = .{ .tab = core.schema.id.tab(raw) catch {
                    diagnostic.set("notification tab_id is invalid", .{});
                    return error.InvalidConfig;
                } };
                target_count += 1;
            }
            if (try optionalPositiveId(state, absolute, "workspace_id", diagnostic)) |raw| {
                target = .{ .workspace = core.schema.id.workspace(raw) catch {
                    diagnostic.set("notification workspace_id is invalid", .{});
                    return error.InvalidConfig;
                } };
                target_count += 1;
            }
            if (target_count > 1) {
                diagnostic.set("notification accepts only one click target", .{});
                return error.InvalidConfig;
            }
            return .{ .notification = action_mod.Notification.init(
                level,
                @intCast(duration),
                target,
                title,
                body,
            ) catch {
                diagnostic.set("notification title or body is invalid or too long", .{});
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
    \\telar.bar = {}
    \\telar.input = {}
    \\function telar.config(value) return value end
    \\function telar.theme(value) return value end
    \\function telar.plugin(value) return value end
    \\function telar.bar.tabs() return { bar_kind = "tabs" } end
    \\function telar.bar.metrics() return { bar_kind = "metrics" } end
    \\function telar.bar.static(value)
    \\  return { bar_kind = "static", value = value }
    \\end
    \\function telar.bar.dynamic(options)
    \\  return {
    \\    bar_kind = "dynamic",
    \\    every_ms = options.every_ms,
    \\    render = options.render,
    \\  }
    \\end
    \\function telar.bar.command(options)
    \\  return {
    \\    bar_kind = "command",
    \\    command = options.command,
    \\    every_ms = options.every_ms,
    \\    timeout_ms = options.timeout_ms,
    \\    render = options.render,
    \\  }
    \\end
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
    \\function telar.action.navigate_pane(options)
    \\  return { kind = "navigate-pane", direction = options.direction }
    \\end
    \\function telar.action.resize_pane(options)
    \\  return { kind = "resize-pane", direction = options.direction }
    \\end
    \\function telar.action.resize_sidebar(options)
    \\  return { kind = "resize-sidebar", direction = options.direction }
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
    \\function telar.action.command_tab(options)
    \\  return { kind = "command-tab", command = options.command, label = options.label }
    \\end
    \\function telar.action.notification(options)
    \\  return {
    \\    kind = "notification",
    \\    title = options.title,
    \\    body = options.body,
    \\    level = options.level,
    \\    duration_ms = options.duration_ms,
    \\    pane_id = options.pane_id,
    \\    tab_id = options.tab_id,
    \\    workspace_id = options.workspace_id,
    \\  }
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

fn validProxyHostname(host: []const u8) bool {
    if (host.len == 0 or host.len > max_proxy_passthrough_host_bytes) return false;
    var label_len: usize = 0;
    for (host) |byte| switch (byte) {
        '.' => {
            if (label_len == 0 or label_len > 63) return false;
            label_len = 0;
        },
        '-' => {
            if (label_len == 0) return false;
            label_len += 1;
        },
        else => {
            if (!std.ascii.isAlphanumeric(byte)) return false;
            label_len += 1;
        },
    };
    if (label_len == 0 or label_len > 63 or host[host.len - 1] == '-') return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| if (label[label.len - 1] == '-') return false;
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

fn optionalStringField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    default: []const u8,
    diagnostic: *Diagnostic,
) ![]const u8 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default;
    return string(state, -1) orelse {
        diagnostic.set("action.{s} must be a string", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
}

fn optionalIntegerField(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    default: lua.lua_Integer,
    diagnostic: *Diagnostic,
) !lua.lua_Integer {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return default;
    return integer(state, -1) orelse {
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
}

fn optionalPositiveId(
    state: *lua.lua_State,
    index: c_int,
    name: [*:0]const u8,
    diagnostic: *Diagnostic,
) !?u64 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return null;
    const value = integer(state, -1) orelse {
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(name)});
        return error.InvalidConfig;
    };
    if (value <= 0) {
        diagnostic.set("action.{s} must be positive", .{std.mem.span(name)});
        return error.InvalidConfig;
    }
    return @intCast(value);
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

fn ensureArrayOnly(
    state: *lua.lua_State,
    index: c_int,
    count: usize,
    path: []const u8,
    diagnostic: *Diagnostic,
) !void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        if (lua.lua_type(state, -2) != lua.LUA_TNUMBER or lua.lua_isinteger(state, -2) == 0) {
            pop(state, 2);
            diagnostic.set("{s} must be an array", .{path});
            return error.InvalidConfig;
        }
        const key = integer(state, -2).?;
        const valid = key >= 1 and key <= count;
        pop(state, 1);
        if (!valid) {
            pop(state, 1);
            diagnostic.set("{s} must be an array", .{path});
            return error.InvalidConfig;
        }
    }
}

fn parseBarInterval(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !u64 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, "every_ms");
    defer pop(state, 1);
    const value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        1_000
    else
        integer(state, -1) orelse {
            diagnostic.set("bar every_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    if (value < bars.min_interval_ms or value > bars.max_interval_ms) {
        diagnostic.set(
            "bar every_ms must be in {d}..{d}",
            .{ bars.min_interval_ms, bars.max_interval_ms },
        );
        return error.InvalidConfig;
    }

    return @as(u64, @intCast(value)) * std.time.ns_per_ms;
}

fn parseBarContent(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !bars.Content {
    const absolute = lua.lua_absindex(state, index);
    var content: bars.Content = .{};
    if (lua.lua_type(state, absolute) == lua.LUA_TNIL) {
        return content;
    }
    if (string(state, absolute)) |value| {
        content.append(value, null, .{}) catch |err| {
            diagnostic.set("invalid bar text: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("bar render must return nil, text, a segment, or an array of segments", .{});
        return error.InvalidBarContent;
    }

    _ = lua.lua_getfield(state, absolute, "text");
    const has_text = lua.lua_type(state, -1) != lua.LUA_TNIL;
    pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "icon");
    const has_icon = lua.lua_type(state, -1) != lua.LUA_TNIL;
    pop(state, 1);
    if (has_text or has_icon) {
        const segment = try parseBarSegment(state, absolute, diagnostic);
        content.append(segment.text, segment.icon, segment.style) catch |err| {
            diagnostic.set("invalid bar segment: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }

    const count = lua.lua_rawlen(state, absolute);
    if (count > bars.max_segments) {
        diagnostic.set("bar content exceeds {d} segments", .{bars.max_segments});
        return error.InvalidBarContent;
    }
    try ensureArrayOnly(state, absolute, count, "bar content", diagnostic);
    for (0..count) |segment_index| {
        _ = lua.lua_geti(state, absolute, @intCast(segment_index + 1));
        const segment = parseBarSegment(state, -1, diagnostic) catch |err| {
            pop(state, 1);
            return err;
        };
        content.append(segment.text, segment.icon, segment.style) catch |err| {
            pop(state, 1);
            diagnostic.set("invalid bar segment {d}: {s}", .{ segment_index + 1, @errorName(err) });
            return error.InvalidBarContent;
        };
        pop(state, 1);
    }

    return content;
}

const ParsedBarSegment = struct {
    text: []const u8,
    icon: ?icons.Icon,
    style: bars.Style,
};

fn parseBarSegment(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !ParsedBarSegment {
    const absolute = lua.lua_absindex(state, index);
    if (string(state, absolute)) |value| {
        return .{ .text = value, .icon = null, .style = .{} };
    }
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("bar segment must be text or a table", .{});
        return error.InvalidBarContent;
    }

    try ensureOnlyFields(
        state,
        absolute,
        &.{ "text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough" },
        "bar segment",
        diagnostic,
    );
    _ = lua.lua_getfield(state, absolute, "text");
    const text_value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        ""
    else
        string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("bar segment text must be a string", .{});
            return error.InvalidBarContent;
        };
    pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "icon");
    const icon_value: ?icons.Icon = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        null
    else icon: {
        const name = string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("bar segment icon must be a string", .{});
            return error.InvalidBarContent;
        };
        break :icon parseBarIcon(name) orelse {
            diagnostic.set("unknown bar icon '{s}'", .{name});
            pop(state, 1);
            return error.InvalidBarContent;
        };
    };
    pop(state, 1);

    var style: bars.Style = .{};
    inline for (.{ .{ "fg", "foreground" }, .{ "bg", "background" } }) |field| {
        _ = lua.lua_getfield(state, absolute, field[0]);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            @field(style, field[1]) = try parseBarColor(state, -1, diagnostic);
        }
        pop(state, 1);
    }
    inline for (.{ "bold", "italic", "faint", "underline", "strikethrough" }) |field| {
        _ = lua.lua_getfield(state, absolute, field);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("bar segment {s} must be a boolean", .{field});
                return error.InvalidBarContent;
            }
            @field(style, field) = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);
    }

    return .{ .text = text_value, .icon = icon_value, .style = style };
}

fn parseBarColor(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !bars.Color {
    if (integer(state, index)) |value| {
        if (value < 0 or value > 255) {
            diagnostic.set("bar color index must be in 0..255", .{});
            return error.InvalidBarContent;
        }

        return .{ .value = .{ .indexed = @intCast(value) } };
    }

    const name = string(state, index) orelse {
        diagnostic.set("bar color must be a palette name, #RRGGBB, default, or an index", .{});
        return error.InvalidBarContent;
    };
    if (std.ascii.eqlIgnoreCase(name, "default")) {
        return .{ .value = .default };
    }
    inline for (std.meta.fields(bars.PaletteColor)) |field| {
        if (normalizedNameEql(name, field.name)) {
            return .{ .palette = @enumFromInt(field.value) };
        }
    }
    if (name.len == 7 and name[0] == '#') {
        const value = std.fmt.parseInt(u24, name[1..], 16) catch {
            diagnostic.set("bar color '{s}' is not #RRGGBB", .{name});
            return error.InvalidBarContent;
        };
        return .{ .value = .{ .rgb = .{
            @intCast((value >> 16) & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast(value & 0xff),
        } } };
    }

    diagnostic.set("unknown bar color '{s}'", .{name});
    return error.InvalidBarContent;
}

fn parseBarIcon(name: []const u8) ?icons.Icon {
    inline for (std.meta.fields(icons.Icon)) |field| {
        if (normalizedNameEql(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

fn normalizedNameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) {
        return false;
    }
    for (left, right) |left_byte, right_byte| {
        const normalized_left = if (left_byte == '-') '_' else std.ascii.toLower(left_byte);
        const normalized_right = if (right_byte == '-') '_' else std.ascii.toLower(right_byte);
        if (normalized_left != normalized_right) {
            return false;
        }
    }

    return true;
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

    freezeTable(state);
}

fn pushReadonlyBarContext(state: *lua.lua_State, context: BarCallbackContext) void {
    lua.lua_createtable(state, 0, 9);
    setBooleanField(state, -1, "sidebar_visible", context.client.sidebar_visible);
    setIntegerField(state, -1, "tab_count", context.client.tab_count);
    setIntegerField(state, -1, "active_tab_index", @as(u32, context.client.active_tab_index) + 1);
    setIntegerField(state, -1, "pane_count", context.client.pane_count);
    setIntegerField(state, -1, "focused_pane_id", context.client.focused_pane_id);

    lua.lua_createtable(state, 0, 8);
    setIntegerField(state, -1, "unix_seconds", context.time.unix_seconds);
    setIntegerField(state, -1, "year", context.time.year);
    setIntegerField(state, -1, "month", context.time.month);
    setIntegerField(state, -1, "day", context.time.day);
    setIntegerField(state, -1, "hour", context.time.hour);
    setIntegerField(state, -1, "minute", context.time.minute);
    setIntegerField(state, -1, "second", context.time.second);
    setIntegerField(state, -1, "weekday", context.time.weekday);
    freezeTable(state);
    lua.lua_setfield(state, -2, "time");

    lua.lua_createtable(state, 0, 4);
    setBooleanField(state, -1, "available", context.metrics != null);
    if (context.metrics) |metrics| {
        setIntegerField(state, -1, "cpu_percent", metrics.cpu_percent);
        setIntegerField(state, -1, "memory_used_decigib", metrics.memory_used_decigib);
        if (metrics.battery_percent) |battery| {
            setIntegerField(state, -1, "battery_percent", battery);
        }
    }
    freezeTable(state);
    lua.lua_setfield(state, -2, "metrics");

    if (context.command_output) |output| {
        _ = lua.lua_pushlstring(state, output.ptr, output.len);
        lua.lua_setfield(state, -2, "output");
    }

    _ = lua.lua_pushlstring(state, context.pane_title.ptr, context.pane_title.len);
    lua.lua_setfield(state, -2, "pane_title");

    freezeTable(state);
}

/// Appends one optional string array of a manifest entry to its bounded list.
fn parseManifestList(state: *lua.lua_State, entry: c_int, comptime field: [:0]const u8, list: anytype, position: usize, diagnostic: *Diagnostic) !void {
    _ = lua.lua_getfield(state, entry, field.ptr);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.agents[{d}]." ++ field ++ " must be an array of strings", .{position});
        return error.InvalidConfig;
    }

    const array = lua.lua_absindex(state, -1);
    const count = lua.lua_rawlen(state, array);
    try ensureArrayOnly(state, array, count, "config.runtime.agents[]." ++ field, diagnostic);
    for (1..count + 1) |item| {
        _ = lua.lua_rawgeti(state, array, @intCast(item));
        defer pop(state, 1);
        var len: usize = 0;
        var text: []const u8 = "";
        if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
            if (lua.lua_tolstring(state, -1, &len)) |raw| text = raw[0..len];
        }
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or hasControlBytes(text)) {
            diagnostic.set("config.runtime.agents[{d}]." ++ field ++ "[{d}] must be a printable string", .{ position, item });
            return error.InvalidConfig;
        }

        list.append(text) catch |err| {
            diagnostic.set("config.runtime.agents[{d}]." ++ field ++ "[{d}] {s}", .{ position, item, switch (err) {
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
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
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
        \\  icons = "nerd-font",
        \\  theme = telar.theme({
        \\    base = "vesper",
        \\    colors = { accent = "#010203" },
        \\  }),
        \\  sidebar = { visible = false, renderer = "cells" },
        \\  pane_gaps = false,
        \\  sound = { enabled = true, ready = false, needs_input = true },
        \\  input = { escape_timeout_ms = 40, sequence_timeout_ms = 750 },
        \\  keybindings = {
        \\    telar.bind({ "%" }, telar.action.split_pane({ direction = "horizontal" })),
        \\    telar.bind({ "g" }, function(ctx)
        \\      return telar.action.toggle_sidebar()
        \\    end),
        \\    telar.bind_global({ "ctrl+g" }, telar.action.detach()),
        \\    telar.bind({ "R" }, telar.action.resize_pane({ direction = "right" })),
        \\    telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
        \\    telar.bind({ "S" }, telar.action.resize_sidebar({ direction = "left" })),
        \\    telar.bind_global({ "ctrl+h" }, telar.action.navigate_pane({ direction = "left" })),
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
    try std.testing.expectEqual(@as(u16, 7), generation.snapshot.binding_count);
    try std.testing.expectEqual(@as(u16, 1), generation.callback_count);
    try std.testing.expect(!generation.snapshot.sidebar_visible);
    try std.testing.expect(!generation.snapshot.pane_gaps);
    try std.testing.expect(generation.snapshot.sound.enabled);
    try std.testing.expect(!generation.snapshot.sound.ready);
    try std.testing.expect(generation.snapshot.sound.needs_input);
    try std.testing.expectEqual(icons.Theme.nerd_font, generation.snapshot.icon_theme);
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
    try std.testing.expectEqualDeep(
        action_mod.Action{ .resize_sidebar = .left },
        generation.snapshot.bindings[5].action,
    );
    try std.testing.expectEqualDeep(
        action_mod.Action{ .navigate_pane = .left },
        generation.snapshot.bindings[6].action,
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

test "client config rejects non-boolean sound settings" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, client = { sound = { ready = 1 } } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "config.client.sound.ready must be a boolean",
        diagnostic.message(),
    );
}

test "client config rejects an unknown icon theme" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            "return { api_version = 2, client = { icons = 'emoji' } }",
            "@config.lua",
            1,
            &diagnostic,
        ),
    );
    try std.testing.expectEqualStrings(
        "unknown config.client.icons: emoji",
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

test "Lua callbacks produce bounded clickable notifications" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "n" }, function(ctx)
        \\      return telar.action.notification({
        \\        title = "Agent waiting",
        \\        body = "Review its question",
        \\        level = "warning",
        \\        duration_ms = 3000,
        \\        pane_id = ctx.focused_pane_id,
        \\      })
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
        12,
        &diagnostic,
    );
    defer generation.deinit();
    const batch = try generation.invokeCallback(
        generation.snapshot.bindings[0].action.lua_callback,
        .{
            .sidebar_visible = true,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 42,
        },
        &diagnostic,
    );
    const notification = &batch.items[0].notification;
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(core.schema.NotificationLevel.warning, notification.level);
    try std.testing.expectEqual(@as(u32, 3000), notification.duration_ms);
    try std.testing.expectEqualStrings("Agent waiting", notification.title());
    try std.testing.expectEqualStrings("Review its question", notification.message());
    try std.testing.expectEqual(
        @as(core.schema.PaneId, @enumFromInt(42)),
        notification.target.pane,
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

test "client bars compile styled static dynamic and command sources" {
    const source =
        \\local telar = require("telar")
        \\return telar.config({
        \\  api_version = 2,
        \\  client = { bars = {
        \\    bottom = {
        \\      left = telar.bar.static({
        \\        { icon = "cpu", text = " CPU", fg = "teal", bg = "#010203", bold = true },
        \\        { text = " 42%", fg = 7, italic = true },
        \\      }),
        \\      center = telar.bar.tabs(),
        \\      right = telar.bar.command({
        \\        command = { "quota", "--json" },
        \\        every_ms = 60000,
        \\        timeout_ms = 450,
        \\        render = function(ctx)
        \\          return {
        \\            { text = ctx.output, fg = "accent" },
        \\            { text = " " .. ctx.active_tab_index, underline = ctx.metrics.available },
        \\          }
        \\        end,
        \\      }),
        \\    },
        \\    top = {
        \\      right = telar.bar.dynamic({
        \\        every_ms = 1000,
        \\        render = function(ctx)
        \\          return {
        \\            {
        \\              icon = "battery-full",
        \\              text = string.format(" %04d-%02d-%02d %02d:%02d:%02d %d%%", ctx.time.year, ctx.time.month, ctx.time.day, ctx.time.hour, ctx.time.minute, ctx.time.second, ctx.metrics.battery_percent),
        \\              fg = "text",
        \\              faint = not ctx.metrics.available,
        \\            },
        \\          }
        \\        end,
        \\      }),
        \\    },
        \\  } },
        \\})
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        8,
        &diagnostic,
    );
    defer generation.deinit();

    const left = &generation.snapshot.bars.bottom[0].static;
    try std.testing.expectEqual(@as(u8, 2), left.segment_count);
    try std.testing.expectEqual(icons.Icon.cpu, left.slice()[0].icon.?);
    try std.testing.expectEqualStrings(" CPU", left.text(left.slice()[0]));
    try std.testing.expectEqualDeep(bars.Color{ .palette = .teal }, left.slice()[0].style.foreground.?);
    try std.testing.expectEqualDeep(bars.Color{ .value = .{ .rgb = .{ 1, 2, 3 } } }, left.slice()[0].style.background.?);
    try std.testing.expect(left.slice()[0].style.bold);
    try std.testing.expectEqualDeep(bars.Color{ .value = .{ .indexed = 7 } }, left.slice()[1].style.foreground.?);
    try std.testing.expect(left.slice()[1].style.italic);
    try std.testing.expect(generation.snapshot.bars.bottom[1] == .tabs);

    const command = &generation.snapshot.bars.bottom[2].command;
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), command.interval_ns);
    try std.testing.expectEqual(@as(u32, 450), command.timeout_ms);
    try std.testing.expectEqualStrings("quota", command.argument(0).?);
    try std.testing.expectEqualStrings("--json", command.argument(1).?);
    try std.testing.expectEqual(@as(u64, 8), command.render.?.generation);

    const context: BarCallbackContext = .{
        .client = .{
            .sidebar_visible = true,
            .tab_count = 4,
            .active_tab_index = 2,
            .pane_count = 3,
            .focused_pane_id = 19,
        },
        .time = .{
            .unix_seconds = 1_788_278_709,
            .year = 2026,
            .month = 9,
            .day = 1,
            .hour = 13,
            .minute = 5,
            .second = 9,
            .weekday = 2,
        },
        .metrics = .{
            .cpu_percent = 38,
            .memory_used_decigib = 123,
            .battery_percent = 61,
        },
    };
    const top = generation.snapshot.bars.top_right.dynamic;
    const clock = try generation.invokeBar(.{ .reference = top.callback, .context = context }, &diagnostic);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), top.interval_ns);
    try std.testing.expectEqual(@as(u8, 1), clock.segment_count);
    try std.testing.expectEqual(icons.Icon.battery_full, clock.slice()[0].icon.?);
    try std.testing.expectEqualStrings(" 2026-09-01 13:05:09 61%", clock.text(clock.slice()[0]));
    try std.testing.expect(!clock.slice()[0].style.faint);

    var command_context = context;
    command_context.command_output = "74%";
    const quota = try generation.invokeBar(.{
        .reference = command.render.?,
        .context = command_context,
    }, &diagnostic);
    try std.testing.expectEqual(@as(u8, 2), quota.segment_count);
    try std.testing.expectEqualStrings("74%", quota.text(quota.slice()[0]));
    try std.testing.expectEqualStrings(" 3", quota.text(quota.slice()[1]));
    try std.testing.expect(quota.slice()[1].style.underline);
}

test "bar callback context tables are immutable" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { bars = {
        \\  bottom = {
        \\    left = telar.bar.dynamic({ render = function(ctx)
        \\      ctx.time.hour = 0
        \\      return "unreachable"
        \\    end }),
        \\    right = telar.bar.tabs(),
        \\  },
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
        "@config.lua",
        9,
        &diagnostic,
    );
    defer generation.deinit();
    const callback = generation.snapshot.bars.bottom[0].dynamic.callback;

    try std.testing.expectError(error.LuaBarCallbackFailed, generation.invokeBar(.{
        .reference = callback,
        .context = .{
            .client = .{ .sidebar_visible = true, .tab_count = 1, .active_tab_index = 0, .pane_count = 1, .focused_pane_id = 1 },
            .time = .{ .unix_seconds = 1, .year = 2026, .month = 9, .day = 1, .hour = 12, .minute = 0, .second = 0, .weekday = 2 },
            .metrics = null,
        },
    }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "immutable") != null);
}

test "client bars reject invalid positions timing and tab ownership" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.metrics() } } } }",
            .message = "exactly one telar.bar.tabs()",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.tabs(), right = t.bar.tabs() } } } }",
            .message = "exactly one telar.bar.tabs()",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { top = { left = t.bar.static('x') } } } }",
            .message = "unknown field config.client.bars.top.left",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { top = { right = t.bar.tabs() } } } }",
            .message = "top.right cannot contain tabs",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.dynamic({ every_ms = 99, render = function() end }), right = t.bar.tabs() } } } }",
            .message = "every_ms must be in 100..3600000",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.command({ command = {}, timeout_ms = 99 }), right = t.bar.tabs() } } } }",
            .message = "timeout_ms must be in 100..10000",
        },
    };

    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            case.source,
            "@config.lua",
            1,
            &diagnostic,
        ));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
}

test "runtime config compiles bounded graphics, proxy, and description values" {
    var diagnostic: Diagnostic = .{};
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    history = { path = "state/history.db" },
        \\    graphics = { pane_mib = 32, global_mib = 128 },
        \\    proxy = {
        \\      enabled = true,
        \\      ca_dir = "state/proxy",
        \\      passthrough_hosts = { "updates.example.com", "API.EXAMPLE.COM" },
        \\    },
        \\    agent_descriptions = {
        \\      command = { "claude", "--print", "--tools", "" },
        \\      timeout_ms = 12000,
        \\    },
        \\  },
        \\}
    ;
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        source,
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
    var passthrough_host_storage: [max_proxy_passthrough_hosts][]const u8 = undefined;
    const passthrough_hosts = generation.snapshot.runtime.proxyPassthroughHosts(
        &passthrough_host_storage,
    );
    try std.testing.expectEqual(@as(usize, 2), passthrough_hosts.len);
    try std.testing.expectEqualStrings("api.example.com", passthrough_hosts[0]);
    try std.testing.expectEqualStrings("updates.example.com", passthrough_hosts[1]);
    var arguments: [max_agent_description_command_args][]const u8 = undefined;
    const description_command = &generation.snapshot.runtime.agent_descriptions;
    try std.testing.expect(description_command.enabled());
    try std.testing.expectEqual(@as(u32, 12_000), description_command.timeout_ms);
    const argv = description_command.arguments(&arguments);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("", argv[3]);
}

test "runtime proxy rejects unsafe passthrough host patterns" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "return { api_version = 2, runtime = { proxy = { passthrough_hosts = { '*.example.com' } } } }",
            .message = "is not a valid hostname",
        },
        .{
            .source = "local h = {}; for i = 1, 257 do h[i] = 'host' .. i .. '.example' end; return { api_version = 2, runtime = { proxy = { passthrough_hosts = h } } }",
            .message = "exceeds 256 entries",
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidConfig,
            Generation.loadSource(
                std.testing.allocator,
                std.testing.io,
                case.source,
                "@config.lua",
                1,
                &diagnostic,
            ),
        );
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
}

test "runtime proxy accepts and sorts 256 passthrough hosts" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "local h = {}; for i = 256, 1, -1 do h[#h + 1] = 'host' .. i .. '.example' end; return { api_version = 2, runtime = { proxy = { passthrough_hosts = h } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    var storage: [max_proxy_passthrough_hosts][]const u8 = undefined;
    const hosts = generation.snapshot.runtime.proxyPassthroughHosts(&storage);
    try std.testing.expectEqual(@as(usize, 256), hosts.len);
    for (hosts[1..], hosts[0 .. hosts.len - 1]) |current, previous|
        try std.testing.expect(core.proxy.orderHostname(previous, current) == .lt);
}

test "proxy passthrough host validation requires exact DNS labels" {
    try std.testing.expect(validProxyHostname("api.github.com"));
    try std.testing.expect(validProxyHostname("API-2.example"));
    try std.testing.expect(!validProxyHostname(""));
    try std.testing.expect(!validProxyHostname(".example.com"));
    try std.testing.expect(!validProxyHostname("example.com."));
    try std.testing.expect(!validProxyHostname("-api.example.com"));
    try std.testing.expect(!validProxyHostname("api-.example.com"));
    try std.testing.expect(!validProxyHostname("*.example.com"));
}

test "runtime description command rejects unbounded values" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "local c = {}; for i = 1, 33 do c[i] = 'x' end; return { api_version = 2, runtime = { agent_descriptions = { command = c } } }",
            .message = "must contain 1..32 arguments",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex', string.rep('x', 4096) } } } }",
            .message = "exceeds its 4096-byte limit",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex' }, timeout_ms = 999 } } }",
            .message = "timeout_ms must be in 1000..60000",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex', extra = true } } } }",
            .message = "command must be an array",
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
            std.testing.allocator,
            std.testing.io,
            case.source,
            "@config.lua",
            1,
            &diagnostic,
        ));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
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

test {
    // Only referenced through non-pub imports above, so its tests never run
    // unless the container is referenced here.
    _ = default_bindings;
}

test "runtime agents extend built-ins and add custom manifests" {
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    agents = {
        \\      { name = "gemini", process_names = { "gemini" }, process_paths = { "/@google/gemini-cli/" },
        \\        brand = { "gemini" }, identity = { "gemini cli" }, working = { "esc to cancel" } },
        \\      { name = "claude", working = { "brewing" } },
        \\    },
        \\  },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(std.testing.allocator, std.testing.io, source, "@config.lua", 1, &diagnostic);
    defer generation.deinit();
    const table = &generation.snapshot.runtime.agent_manifests;

    try std.testing.expectEqual(@as(u8, 3), table.count);
    const gemini = table.find(@enumFromInt(core.schema.first_custom_agent_provider)).?;
    try std.testing.expectEqualStrings("gemini", gemini.nameSlice());
    try std.testing.expectEqual(gemini.provider, table.providerFromExecutable("gemini").?);
    try std.testing.expectEqual(gemini.provider, table.detect("Gemini CLI  esc to cancel").?.provider);
    try std.testing.expectEqual(core.agent_manifest.Status.working, table.detect("brewing").?.status);
    try std.testing.expectEqual(core.schema.AgentProvider.claude, table.detect("Claude Code").?.provider);
}

test "runtime agents reject bad names and oversized phrases" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { agents = { { name = \"Gemini\" } } } }",
        "@config.lua",
        1,
        &diagnostic,
    ));
    try std.testing.expect(std.mem.startsWith(u8, diagnostic.message(), "config.runtime.agents[1].name must be"));

    var long_phrase: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { agents = { { name = \"x\", working = { string.rep(\"a\", 49) } } } } }",
        "@config.lua",
        1,
        &long_phrase,
    ));
    try std.testing.expectEqualStrings("config.runtime.agents[1].working[1] is too long", long_phrase.message());
}

test "notification delivery parses and rejects unknown channels" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { notifications = { delivery = \"system\" } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectEqual(config_model.NotificationDelivery.system, generation.snapshot.notification_delivery);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { notifications = { delivery = \"popup\" } } }",
        "@config.lua",
        1,
        &invalid,
    ));
    try std.testing.expectEqualStrings("config.client.notifications.delivery must be telar, terminal or system", invalid.message());
}

test "appearance themes parse and reject unknown names" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { appearance = { light = \"catppuccin\", dark = \"vesper\" } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expectEqual(theme_mod.Builtin.catppuccin, generation.snapshot.theme_light.?.base);
    try std.testing.expectEqual(theme_mod.Builtin.vesper, generation.snapshot.theme_dark.?.base);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { appearance = { light = \"neon\" } } }",
        "@config.lua",
        1,
        &invalid,
    ));
}

test "command-tab actions parse a bounded argv and reject empty commands" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { keybindings = { telar.bind({ \"ctrl+g\" }, telar.action.command_tab({ command = { \"lazygit\", \"-p\" }, label = \"git\" })) } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();

    const parsed = generation.snapshot.bindings[0].action.command_tab;
    try std.testing.expectEqualStrings("lazygit", parsed.argument(0));
    try std.testing.expectEqualStrings("-p", parsed.argument(1));
    try std.testing.expectEqualStrings("git", parsed.label());

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { keybindings = { telar.bind({ \"ctrl+g\" }, telar.action.command_tab({ command = {} })) } } }",
        "@config.lua",
        1,
        &invalid,
    ));
}

test "runtime history filters parse and reject invalid patterns" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { history = { secrets_filter = false, command_filters = { \"vault kv\" }, cwd_filters = { \"/private\" } } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();

    const filters = generation.snapshot.runtime.history_filters;
    try std.testing.expect(!filters.secrets);
    try std.testing.expectEqualStrings("vault kv", filters.commands.at(0));
    try std.testing.expectEqualStrings("/private", filters.cwds.at(0));
    try std.testing.expectEqual(@as(?[]const u8, null), generation.snapshot.runtime.historyPath());

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { history = { command_filters = { \"\" } } } }",
        "@config.lua",
        1,
        &invalid,
    ));

    var bad_flag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, runtime = { history = { secrets_filter = \"yes\" } } }",
        "@config.lua",
        1,
        &bad_flag,
    ));
}

test "client history config toggles agent command visibility" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { show_agent_commands = true } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_show_agent_commands);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { show_agent_commands = \"yes\" } } }",
        "@config.lua",
        1,
        &invalid,
    ));
}

test "client history enter mode parses paste or run only" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { enter = \"run\" } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_enter_runs);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { enter = \"always\" } } }",
        "@config.lua",
        1,
        &invalid,
    ));
}

test "client history match mode parses fuzzy or fts only" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { match = \"fts\" } } }",
        "@config.lua",
        1,
        &diagnostic,
    );
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_match_fts);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(
        std.testing.allocator,
        std.testing.io,
        "return { api_version = 2, client = { history = { match = \"regex\" } } }",
        "@config.lua",
        1,
        &invalid,
    ));
}
