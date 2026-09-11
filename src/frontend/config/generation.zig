const Generation = @This();
const std = @import("std");
const source_namespace = @import("generation_support.zig");
const Callback = @import("Callback.zig");
const BarCallback = @import("BarCallback.zig");
const LoadContext = @import("LoadContext.zig");
const SourceInput = @import("SourceInput.zig");
const config_model = @import("model.zig");
const lua = @import("lua-api").c;
const FileInput = @import("FileInput.zig");
const CallbackInvocation = @import("CallbackInvocation.zig");
const bars = @import("../bars/root.zig");
const CallbackPreparation = @import("CallbackPreparation.zig");
const lua_runtime = @import("telar-lua");
const plugins_config = @import("plugins.zig");
const commands_config = @import("commands.zig");
const session_config = @import("session.zig");
const agents_config = @import("agents.zig");
const history_config = @import("history.zig");
const proxy_config = @import("proxy.zig");
const core = @import("telar-core");
const client_history_config = @import("client_history.zig");
const theme_config = @import("theme.zig");
const icons = @import("../ui/root.zig").icons;
const notifications_config = @import("notifications.zig");
const kitty = @import("../graphics/root.zig").kitty;
gpa: std.mem.Allocator,
number: u64,
vm: *source_namespace.Vm,
snapshot: source_namespace.Snapshot = .{},
callbacks: [source_namespace.max_callbacks]Callback = undefined,
callback_count: u16 = 0,
bar_callbacks: [source_namespace.max_bar_callbacks]BarCallback = undefined,
bar_callback_count: u8 = 0,
modules: @import("local_modules.zig").State,
profile_bytes: [source_namespace.max_profile_name_bytes]u8 = undefined,
profile_len: u8 = 0,

/// Compiles configuration source within the supplied loading environment.
/// For example: `Generation.loadSource(context, .{ .source = bytes, .source_name = "@config.lua", .number = 1 })`.
pub fn loadSource(context: LoadContext, spec: SourceInput) !*Generation {
    if (spec.profile) |name| {
        if (!source_namespace.validProfileName(name)) {
            context.diagnostic.set("invalid profile name '{s}'", .{name});
            return error.InvalidProfileName;
        }
    }
    const generation = try context.gpa.create(Generation);
    errdefer context.gpa.destroy(generation);
    generation.* = .{
        .gpa = context.gpa,
        .number = spec.number,
        .vm = try source_namespace.Vm.init(context.io, .{
            .memory = config_model.default_memory_limit,
            .instructions = config_model.default_load_instruction_limit,
            .deadline_after_ns = (config_model.Limits{}).deadline_after_ns,
        }),
        .modules = undefined,
    };
    errdefer generation.vm.deinit();
    generation.modules = try .init(generation.vm, spec.config_dir);
    if (spec.profile) |name| {
        @memcpy(generation.profile_bytes[0..name.len], name);
        generation.profile_len = @intCast(name.len);
    }

    generation.openEnvironment() catch |err| {
        context.diagnostic.set("failed to initialize Lua: {s}", .{@errorName(err)});
        return err;
    };
    generation.vm.resetBudget(source_namespace.default_load_instruction_limit, 100 * std.time.ns_per_ms);
    generation.vm.execute(.{ .source = source_namespace.bootstrap, .name = "@telar/bootstrap.lua", .results = 0 }) catch |err| {
        context.diagnostic.set("failed to initialize telar Lua API: {s}", .{generation.vm.errorMessage()});
        return err;
    };
    generation.installRequire();
    generation.vm.execute(.{ .source = spec.source, .name = spec.source_name, .results = 1 }) catch |err| {
        context.diagnostic.set("{s}", .{generation.vm.errorMessage()});
        return err;
    };
    generation.parseSnapshot(context.diagnostic) catch |err| return err;
    generation.syncCallbackTriggers();
    lua.lua_settop(generation.vm.state, 0);
    return generation;
}

/// Reads and compiles one configuration file.
/// For example: `Generation.loadFile(context, .{ .path = "config.lua", .number = 1 })`.
pub fn loadFile(context: LoadContext, spec: FileInput) !*Generation {
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path_len = source_namespace.Io.Dir.cwd().realPathFile(context.io, spec.path, &real_path_buffer) catch |err| {
        context.diagnostic.set("cannot resolve config '{s}': {s}", .{ spec.path, @errorName(err) });
        return err;
    };
    const real_path = real_path_buffer[0..real_path_len];
    const source = source_namespace.Io.Dir.cwd().readFileAlloc(
        context.io,
        real_path,
        context.gpa,
        .limited(source_namespace.max_config_bytes),
    ) catch |err| {
        context.diagnostic.set("cannot read config '{s}': {s}", .{ spec.path, @errorName(err) });
        return err;
    };
    defer context.gpa.free(source);
    const config_dir = std.fs.path.dirname(real_path) orelse ".";
    return loadSource(context, .{
        .source = source,
        .source_name = "@config.lua",
        .config_dir = config_dir,
        .number = spec.number,
        .profile = spec.profile,
    });
}

pub fn deinit(generation: *Generation) void {
    generation.vm.deinit();
    generation.gpa.destroy(generation);
}

pub fn dependencyPath(generation: *const Generation, index: usize) ?[]const u8 {
    return generation.modules.dependencyPath(index);
}

pub fn watchFingerprint(generation: *const Generation, io: source_namespace.Io, config_path: []const u8) i128 {
    return generation.modules.watchFingerprint(io, config_path);
}

pub fn configDir(generation: *const Generation) []const u8 {
    return generation.modules.configDir();
}

pub fn pluginSlice(generation: *const Generation) []const source_namespace.PluginSpec {
    return generation.snapshot.plugins[0..generation.snapshot.plugin_count];
}

fn installRequire(generation: *Generation) void {
    return generation.modules.installRequire();
}

/// Runs an action callback against one immutable client snapshot.
/// For example: `generation.invokeCallback(.{ .reference = callback, .context = snapshot }, diagnostic)`.
pub fn invokeCallback(generation: *Generation, invocation: CallbackInvocation, diagnostic: *source_namespace.Diagnostic) !source_namespace.EffectBatch {
    const callback = try generation.prepareCallback(.{ .invocation = invocation, .expression = false }, diagnostic);
    _ = callback;
    const state = generation.vm.state;
    defer lua.lua_settop(state, 0);
    if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
        diagnostic.set("Lua callback failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return generation.parseEffectBatch(-1, diagnostic);
}

/// Runs an input expression against one immutable client snapshot.
/// For example: `generation.invokeExpression(.{ .reference = expression, .context = snapshot }, diagnostic)`.
pub fn invokeExpression(generation: *Generation, invocation: CallbackInvocation, diagnostic: *source_namespace.Diagnostic) !source_namespace.InputDecision {
    const callback = try generation.prepareCallback(.{ .invocation = invocation, .expression = true }, diagnostic);
    const state = generation.vm.state;
    defer lua.lua_settop(state, 0);
    if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
        diagnostic.set("Lua expression failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return source_namespace.parseInputDecision(state, .{ .index = -1, .callback = callback }, diagnostic);
}

pub fn invokeBar(generation: *Generation, invocation: source_namespace.BarInvocation, diagnostic: *source_namespace.Diagnostic) !bars.Content {
    const reference = invocation.reference;
    if (reference.generation != generation.number or reference.id >= generation.bar_callback_count) {
        diagnostic.set("bar callback belongs to an obsolete configuration generation", .{});
        return error.StaleBarCallback;
    }

    const state = generation.vm.state;
    lua.lua_settop(state, 0);
    defer lua.lua_settop(state, 0);
    generation.vm.resetBudget(source_namespace.default_callback_instruction_limit, source_namespace.default_callback_deadline_ns);
    _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, generation.bar_callbacks[reference.id].registry_ref);
    source_namespace.pushReadonlyBarContext(state, invocation.context);
    if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
        diagnostic.set("Lua bar callback failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaBarCallbackFailed;
    }

    return source_namespace.parseBarContent(state, -1, diagnostic);
}

fn prepareCallback(generation: *Generation, preparation: CallbackPreparation, diagnostic: *source_namespace.Diagnostic) !*const Callback {
    const reference = preparation.invocation.reference;
    if (reference.generation != generation.number or reference.id >= generation.callback_count) {
        diagnostic.set("callback belongs to an obsolete configuration generation", .{});
        return error.StaleCallback;
    }
    const callback = &generation.callbacks[reference.id];
    if (callback.expression != preparation.expression) {
        diagnostic.set("callback kind does not match its binding", .{});
        return error.InvalidCallbackKind;
    }
    const state = generation.vm.state;
    lua.lua_settop(state, 0);
    generation.vm.resetBudget(
        source_namespace.default_callback_instruction_limit,
        source_namespace.default_callback_deadline_ns,
    );
    _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, callback.registry_ref);
    source_namespace.pushReadonlyContext(state, preparation.invocation.context);
    return callback;
}

fn parseEffectBatch(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !source_namespace.EffectBatch {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("Lua callback must return an action or an array of actions", .{});
        return error.InvalidCallbackResult;
    }
    var batch: source_namespace.EffectBatch = .{};
    _ = lua.lua_getfield(state, absolute, "kind");
    const single = lua.lua_type(state, -1) != lua.LUA_TNIL;
    source_namespace.pop(state, 1);
    if (single) {
        batch.items[0] = try generation.parseReturnedAction(absolute, diagnostic);
        batch.len = 1;
        return batch;
    }
    const count = lua.lua_rawlen(state, absolute);
    if (count > source_namespace.max_callback_effects) {
        diagnostic.set("Lua callback exceeds {d} effects", .{source_namespace.max_callback_effects});
        return error.InvalidCallbackResult;
    }
    for (0..count) |effect_index| {
        _ = lua.lua_geti(state, absolute, @intCast(effect_index + 1));
        batch.items[effect_index] = generation.parseReturnedAction(-1, diagnostic) catch |err| {
            source_namespace.pop(state, 1);
            return err;
        };
        source_namespace.pop(state, 1);
    }
    batch.len = @intCast(count);
    return batch;
}

fn parseReturnedAction(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !source_namespace.action_mod.Action {
    if (lua.lua_type(generation.vm.state, index) == lua.LUA_TFUNCTION) {
        diagnostic.set("a callback cannot return another callback", .{});
        return error.InvalidCallbackResult;
    }
    const action = generation.parseAction(.{ .index = index, .expression = false }, diagnostic) catch
        return error.InvalidCallbackResult;
    return switch (action) {
        .lua_callback, .lua_expr => error.InvalidCallbackResult,
        else => action,
    };
}

fn openEnvironment(generation: *Generation) !void {
    try lua_runtime.sandbox.open(generation.vm.state);
}

fn parseSnapshot(generation: *Generation, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.lua must return a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{ .index = -1, .allowed = &.{ "api_version", "client", "runtime", "plugins", "profiles" }, .path = "config" }, diagnostic);

    _ = lua.lua_getfield(state, -1, "api_version");
    const version = source_namespace.integer(state, -1) orelse {
        source_namespace.pop(state, 1);
        diagnostic.set("config.api_version must be an integer", .{});
        return error.InvalidConfig;
    };
    source_namespace.pop(state, 1);
    if (version != source_namespace.api_version) {
        diagnostic.set(
            "config.api_version is {d}; this Telar accepts {d}",
            .{ version, source_namespace.api_version },
        );
        return error.IncompatibleConfigApi;
    }

    _ = lua.lua_getfield(state, -1, "plugins");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try plugins_config.parse(state, &generation.snapshot, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, -1, "client");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseClient(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, -1, "runtime");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseRuntime(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, -1, "profiles");
    defer source_namespace.pop(state, 1);
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

fn parseProfile(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "client", "runtime", "plugins" }, .path = "profile" }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "plugins");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try plugins_config.parse(state, &generation.snapshot, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "client");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseClient(-1, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "runtime");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseRuntime(-1, diagnostic);
    }
    source_namespace.pop(state, 1);
}

fn parseProfiles(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    const base_snapshot = generation.snapshot;
    var selected_snapshot: ?source_namespace.Snapshot = null;
    const selected_name = generation.profile_bytes[0..generation.profile_len];
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        const name = source_namespace.string(state, -2) orelse {
            source_namespace.pop(state, 2);
            diagnostic.set("config.profiles contains a non-string name", .{});
            return error.InvalidConfig;
        };
        if (!source_namespace.validProfileName(name)) {
            diagnostic.set("invalid profile name '{s}'", .{name});
            source_namespace.pop(state, 2);
            return error.InvalidConfig;
        }
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("profile '{s}' must be a table", .{name});
            source_namespace.pop(state, 2);
            return error.InvalidConfig;
        }
        generation.snapshot = base_snapshot;
        generation.parseProfile(-1, diagnostic) catch |err| {
            source_namespace.pop(state, 2);
            return err;
        };
        if (generation.profile_len != 0 and std.mem.eql(u8, name, selected_name)) {
            selected_snapshot = generation.snapshot;
        }
        source_namespace.pop(state, 1);
    }
    generation.snapshot = if (generation.profile_len == 0)
        base_snapshot
    else
        selected_snapshot orelse {
            diagnostic.set("profile '{s}' is not defined", .{selected_name});
            return error.UnknownProfile;
        };
}

fn parseRuntime(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime must be a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "graphics", "history", "proxy", "agent_descriptions", "engine", "agents", "session" },
        .path = "config.runtime",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "engine");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try commands_config.parseEngine(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "session");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try session_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "agents");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try agents_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "history");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try history_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "proxy");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try proxy_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "agent_descriptions");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try commands_config.parseAgentDescriptions(state, &generation.snapshot.runtime, diagnostic);
    }
    source_namespace.pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "graphics");
    defer source_namespace.pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.graphics must be a table", .{});
        return error.InvalidConfig;
    }
    const graphics = lua.lua_absindex(state, -1);
    try source_namespace.ensureOnlyFields(state, .{
        .index = graphics,
        .allowed = &.{ "pane_mib", "global_mib" },
        .path = "config.runtime.graphics",
    }, diagnostic);
    generation.snapshot.runtime.graphics_pane_bytes = try source_namespace.optionalMebibytes(state, .{
        .index = graphics,
        .name = "pane_mib",
        .default = generation.snapshot.runtime.graphics_pane_bytes,
    }, diagnostic);
    generation.snapshot.runtime.graphics_global_bytes = try source_namespace.optionalMebibytes(state, .{
        .index = graphics,
        .name = "global_mib",
        .default = generation.snapshot.runtime.graphics_global_bytes,
    }, diagnostic);
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

fn parseClient(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client must be a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "prefix", "theme", "icons", "sidebar", "pane_gaps", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "history" },
        .path = "config.client",
    }, diagnostic);

    _ = lua.lua_getfield(state, absolute, "prefix");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parsePrefix(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "history");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try client_history_config.parse(state, &generation.snapshot, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "theme");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        generation.snapshot.theme = try theme_config.parse(state, -1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "icons");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        const value = source_namespace.string(state, -1) orelse {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.icons must be a string", .{});
            return error.InvalidConfig;
        };
        generation.snapshot.icon_theme = icons.Theme.parse(value) catch {
            diagnostic.set("unknown config.client.icons: {s}", .{value});
            source_namespace.pop(state, 1);
            return error.InvalidConfig;
        };
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "sidebar");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseSidebar(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "pane_gaps");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.pane_gaps must be a boolean", .{});
            return error.InvalidConfig;
        }
        generation.snapshot.pane_gaps = lua.lua_toboolean(state, -1) != 0;
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "window_title");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(state, -1) != lua.LUA_TSTRING) {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.window_title must be a string", .{});
            return error.InvalidConfig;
        }

        var len: usize = 0;
        const template: []const u8 = if (lua.lua_tolstring(state, -1, &len)) |raw| raw[0..len] else "";
        if (template.len > config_model.max_window_title_bytes or !std.unicode.utf8ValidateSlice(template) or source_namespace.hasControlBytes(template)) {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.window_title must be printable UTF-8 of at most {d} bytes", .{config_model.max_window_title_bytes});
            return error.InvalidConfig;
        }

        @memcpy(generation.snapshot.window_title_bytes[0..template.len], template);
        generation.snapshot.window_title_len = @intCast(template.len);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "sound");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseSound(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "notifications");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try notifications_config.parse(state, &generation.snapshot, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "appearance");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try theme_config.parseAppearance(state, &generation.snapshot, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "input");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseInputOptions(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "keybindings");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseBindings(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "bars");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseBars(-1, diagnostic);
    }
    source_namespace.pop(state, 1);
}

fn parseBars(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.bars must be a table", .{});
        return error.InvalidConfig;
    }

    try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bottom", "top" }, .path = "config.client.bars" }, diagnostic);

    _ = lua.lua_getfield(state, absolute, "bottom");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseBottomBar(-1, diagnostic);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "top");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        try generation.parseTopBar(-1, diagnostic);
    }
    source_namespace.pop(state, 1);
}

fn parseBottomBar(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.bars.bottom must be a table", .{});
        return error.InvalidConfig;
    }

    try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "left", "center", "right" }, .path = "config.client.bars.bottom" }, diagnostic);
    var parsed: [3]bars.Source = .{ .empty, .empty, .empty };
    inline for (.{ "left", "center", "right" }, 0..) |field, source_index| {
        _ = lua.lua_getfield(state, absolute, field);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            parsed[source_index] = try generation.parseBarSource(-1, diagnostic);
        }
        source_namespace.pop(state, 1);
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

fn parseTopBar(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.bars.top must be a table", .{});
        return error.InvalidConfig;
    }

    try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"right"}, .path = "config.client.bars.top" }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "right");
    defer source_namespace.pop(state, 1);
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

fn parseBarSource(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !bars.Source {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("bar position must contain a telar.bar value", .{});
        return error.InvalidConfig;
    }

    _ = lua.lua_getfield(state, absolute, "bar_kind");
    const kind = source_namespace.string(state, -1) orelse {
        source_namespace.pop(state, 1);
        diagnostic.set("bar position must contain a telar.bar value", .{});
        return error.InvalidConfig;
    };
    source_namespace.pop(state, 1);

    if (std.mem.eql(u8, kind, "tabs")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"bar_kind"}, .path = "bar tabs" }, diagnostic);
        return .tabs;
    }
    if (std.mem.eql(u8, kind, "metrics")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"bar_kind"}, .path = "bar metrics" }, diagnostic);
        return .metrics;
    }
    if (std.mem.eql(u8, kind, "static")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "value" }, .path = "bar static block" }, diagnostic);
        _ = lua.lua_getfield(state, absolute, "value");
        defer source_namespace.pop(state, 1);
        return .{ .static = try source_namespace.parseBarContent(state, -1, diagnostic) };
    }
    if (std.mem.eql(u8, kind, "dynamic")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "every_ms", "render" }, .path = "bar dynamic block" }, diagnostic);
        const interval_ns = try source_namespace.parseBarInterval(state, absolute, diagnostic);
        _ = lua.lua_getfield(state, absolute, "render");
        defer source_namespace.pop(state, 1);
        const callback = try generation.registerBarCallback(-1, diagnostic);
        return .{ .dynamic = .{ .callback = callback, .interval_ns = interval_ns } };
    }
    if (std.mem.eql(u8, kind, "command")) {
        return generation.parseBarCommand(absolute, diagnostic);
    }

    diagnostic.set("unknown bar value '{s}'", .{kind});
    return error.InvalidConfig;
}

fn parseBarCommand(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !bars.Source {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "bar_kind", "command", "every_ms", "timeout_ms", "render" },
        .path = "bar command block",
    }, diagnostic);

    const interval_ns = try source_namespace.parseBarInterval(state, absolute, diagnostic);
    _ = lua.lua_getfield(state, absolute, "timeout_ms");
    const timeout_value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        2_000
    else
        source_namespace.integer(state, -1) orelse {
            source_namespace.pop(state, 1);
            diagnostic.set("bar command timeout_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    source_namespace.pop(state, 1);
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
        source_namespace.pop(state, 1);
        diagnostic.set("bar command must be an array", .{});
        return error.InvalidConfig;
    }
    const command_table = lua.lua_absindex(state, -1);
    const count = lua.lua_rawlen(state, command_table);
    if (count == 0 or count > bars.max_command_args) {
        source_namespace.pop(state, 1);
        diagnostic.set("bar command must contain 1..{d} arguments", .{bars.max_command_args});
        return error.InvalidConfig;
    }
    try source_namespace.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "bar command" }, diagnostic);
    for (0..count) |argument_index| {
        _ = lua.lua_geti(state, command_table, @intCast(argument_index + 1));
        const argument_value = source_namespace.string(state, -1) orelse {
            source_namespace.pop(state, 2);
            diagnostic.set("bar command argument {d} must be a string", .{argument_index + 1});
            return error.InvalidConfig;
        };
        command.appendArgument(argument_value) catch |err| {
            source_namespace.pop(state, 2);
            diagnostic.set("invalid bar command: {s}", .{@errorName(err)});
            return error.InvalidConfig;
        };
        source_namespace.pop(state, 1);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "render");
    defer source_namespace.pop(state, 1);
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        command.render = try generation.registerBarCallback(-1, diagnostic);
    }

    return .{ .command = command };
}

fn registerBarCallback(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !bars.CallbackRef {
    const state = generation.vm.state;
    if (lua.lua_type(state, index) != lua.LUA_TFUNCTION) {
        diagnostic.set("bar render must be a Lua function", .{});
        return error.InvalidConfig;
    }
    if (generation.bar_callback_count == source_namespace.max_bar_callbacks) {
        diagnostic.set("configuration exceeds {d} bar callbacks", .{source_namespace.max_bar_callbacks});
        return error.InvalidConfig;
    }

    lua.lua_pushvalue(state, index);
    const registry_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
    const id = generation.bar_callback_count;
    generation.bar_callbacks[id] = .{ .registry_ref = registry_ref };
    generation.bar_callback_count += 1;
    return .{ .generation = generation.number, .id = id };
}

fn parsePrefix(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const value = source_namespace.string(generation.vm.state, index) orelse {
        diagnostic.set("config.client.prefix must be a string", .{});
        return error.InvalidConfig;
    };
    const prefix = source_namespace.keybind.parseKey(value) catch |err| {
        diagnostic.set("invalid config.client.prefix: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };
    generation.snapshot.prefix = prefix;
    for (generation.snapshot.bindings[0..generation.snapshot.binding_count], 0..) |*binding, binding_index| {
        if (generation.snapshot.bindings_prefixed[binding_index]) {
            binding.keys[0] = prefix;
        }
    }
}

fn parseInputOptions(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.input must be a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "escape_timeout_ms", "sequence_timeout_ms" },
        .path = "config.client.input",
    }, diagnostic);
    generation.snapshot.input_escape_timeout_ns = try source_namespace.optionalMilliseconds(state, .{
        .index = absolute,
        .name = "escape_timeout_ms",
        .default_ns = generation.snapshot.input_escape_timeout_ns,
        .minimum_ms = 1,
        .maximum_ms = 1000,
    }, diagnostic);
    generation.snapshot.input_sequence_timeout_ns = try source_namespace.optionalMilliseconds(state, .{
        .index = absolute,
        .name = "sequence_timeout_ms",
        .default_ns = generation.snapshot.input_sequence_timeout_ns,
        .minimum_ms = 10,
        .maximum_ms = 10_000,
    }, diagnostic);
}

fn parseSound(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.sound must be a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "enabled", "ready", "needs_input" },
        .path = "config.client.sound",
    }, diagnostic);
    inline for (.{ "enabled", "ready", "needs_input" }) |field| {
        _ = lua.lua_getfield(state, absolute, field);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                source_namespace.pop(state, 1);
                diagnostic.set("config.client.sound.{s} must be a boolean", .{field});
                return error.InvalidConfig;
            }
            @field(generation.snapshot.sound, field) = lua.lua_toboolean(state, -1) != 0;
        }
        source_namespace.pop(state, 1);
    }
}

fn parseSidebar(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.sidebar must be a table", .{});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "visible", "renderer" },
        .path = "config.client.sidebar",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "visible");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.sidebar.visible must be a boolean", .{});
            return error.InvalidConfig;
        }
        generation.snapshot.sidebar_visible = lua.lua_toboolean(state, -1) != 0;
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "renderer");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        const value = source_namespace.string(state, -1) orelse {
            source_namespace.pop(state, 1);
            diagnostic.set("config.client.sidebar.renderer must be a string", .{});
            return error.InvalidConfig;
        };
        generation.snapshot.sidebar_rendering = kitty.SidebarRendering.parse(value) catch {
            diagnostic.set("unknown sidebar renderer '{s}'", .{value});
            source_namespace.pop(state, 1);
            return error.InvalidConfig;
        };
    }
    source_namespace.pop(state, 1);
}

fn parseBindings(generation: *Generation, index: c_int, diagnostic: *source_namespace.Diagnostic) !void {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.keybindings must be an array", .{});
        return error.InvalidConfig;
    }
    const count = lua.lua_rawlen(state, absolute);
    if (count > source_namespace.max_bindings) {
        diagnostic.set("config.client.keybindings exceeds {d} entries", .{source_namespace.max_bindings});
        return error.InvalidConfig;
    }
    generation.snapshot.binding_count = 0;
    for (0..count) |binding_index| {
        _ = lua.lua_geti(state, absolute, @intCast(binding_index + 1));
        const parsed = generation.parseBinding(.{ .index = -1, .position = binding_index }, diagnostic) catch |err| {
            source_namespace.pop(state, 1);
            return err;
        };
        generation.snapshot.bindings[binding_index] = parsed.binding;
        generation.snapshot.bindings_prefixed[binding_index] = parsed.prefixed;
        source_namespace.pop(state, 1);
    }
    generation.snapshot.binding_count = @intCast(count);
}

const ParsedBinding = struct {
    binding: source_namespace.ConfiguredBinding,
    prefixed: bool,
};

const BindingInput = struct {
    index: c_int,
    position: usize,
};

fn parseBinding(generation: *Generation, binding_input: BindingInput, diagnostic: *source_namespace.Diagnostic) !ParsedBinding {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, binding_input.index);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("keybinding {d} must be a telar.bind value", .{binding_input.position + 1});
        return error.InvalidConfig;
    }
    try source_namespace.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "keys", "action", "expression", "prefixed" },
        .path = "keybinding",
    }, diagnostic);

    _ = lua.lua_getfield(state, absolute, "prefixed");
    const prefixed = if (lua.lua_type(state, -1) == lua.LUA_TBOOLEAN)
        lua.lua_toboolean(state, -1) != 0
    else {
        source_namespace.pop(state, 1);
        diagnostic.set("keybinding {d}.prefixed must be a boolean", .{binding_input.position + 1});
        return error.InvalidConfig;
    };
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "keys");
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        source_namespace.pop(state, 1);
        diagnostic.set("keybinding {d}.keys must be an array", .{binding_input.position + 1});
        return error.InvalidConfig;
    }
    const key_count = lua.lua_rawlen(state, -1);
    const key_limit: usize = if (prefixed) source_namespace.max_binding_suffix_keys else source_namespace.max_binding_keys;
    if (key_count == 0 or key_count > key_limit) {
        source_namespace.pop(state, 1);
        diagnostic.set(
            "keybinding {d}.keys must contain 1..{d} keys",
            .{ binding_input.position + 1, key_limit },
        );
        return error.InvalidConfig;
    }
    var keys: [source_namespace.max_binding_keys]source_namespace.keybind.Key = undefined;
    const key_offset: usize = @intFromBool(prefixed);
    if (prefixed) {
        keys[0] = generation.snapshot.prefix;
    }
    for (0..key_count) |key_index| {
        _ = lua.lua_geti(state, -1, @intCast(key_index + 1));
        const name = source_namespace.string(state, -1) orelse {
            source_namespace.pop(state, 2);
            diagnostic.set(
                "keybinding {d}.keys[{d}] must be a string",
                .{ binding_input.position + 1, key_index + 1 },
            );
            return error.InvalidConfig;
        };
        keys[key_offset + key_index] = source_namespace.keybind.parseKey(name) catch |err| {
            source_namespace.pop(state, 2);
            diagnostic.set(
                "invalid keybinding {d}: {s}",
                .{ binding_input.position + 1, @errorName(err) },
            );
            return error.InvalidConfig;
        };
        source_namespace.pop(state, 1);
    }
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "expression");
    const expression = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        false
    else if (lua.lua_type(state, -1) == lua.LUA_TBOOLEAN)
        lua.lua_toboolean(state, -1) != 0
    else {
        source_namespace.pop(state, 1);
        diagnostic.set("keybinding {d}.expression must be a boolean", .{binding_input.position + 1});
        return error.InvalidConfig;
    };
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "action");
    const action = generation.parseAction(.{ .index = -1, .expression = expression }, diagnostic) catch |err| {
        source_namespace.pop(state, 1);
        return err;
    };
    source_namespace.pop(state, 1);
    const total_key_count = key_offset + key_count;
    const binding = source_namespace.ConfiguredBinding.init(keys[0..total_key_count], action) catch |err| {
        diagnostic.set("invalid keybinding {d}: {s}", .{ binding_input.position + 1, @errorName(err) });
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

const ActionInput = struct {
    index: c_int,
    expression: bool,
};

fn parseAction(generation: *Generation, action_input: ActionInput, diagnostic: *source_namespace.Diagnostic) !source_namespace.action_mod.Action {
    const state = generation.vm.state;
    const absolute = lua.lua_absindex(state, action_input.index);
    if (lua.lua_type(state, absolute) == lua.LUA_TFUNCTION) {
        if (generation.callback_count == source_namespace.max_callbacks) {
            diagnostic.set("configuration exceeds {d} Lua callbacks", .{source_namespace.max_callbacks});
            return error.InvalidConfig;
        }
        lua.lua_pushvalue(state, absolute);
        const registry_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        const id = generation.callback_count;
        generation.callbacks[id] = .{
            .registry_ref = registry_ref,
            .expression = action_input.expression,
        };
        generation.callback_count += 1;
        const reference: source_namespace.action_mod.CallbackRef = .{
            .generation = generation.number,
            .id = id,
        };
        return if (action_input.expression)
            .{ .lua_expr = reference }
        else
            .{ .lua_callback = reference };
    }

    if (source_namespace.string(state, absolute)) |name| {
        if (action_input.expression) {
            diagnostic.set("expression binding action must be a Lua function", .{});
            return error.InvalidConfig;
        }
        return source_namespace.action_mod.Action.parse(name) catch {
            diagnostic.set("unknown action '{s}'", .{name});
            return error.InvalidConfig;
        };
    }

    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("keybinding action must be a string, action, or function", .{});
        return error.InvalidConfig;
    }
    if (action_input.expression) {
        diagnostic.set("expression binding action must be a Lua function", .{});
        return error.InvalidConfig;
    }

    _ = lua.lua_getfield(state, absolute, "kind");
    const kind = source_namespace.string(state, -1) orelse {
        source_namespace.pop(state, 1);
        diagnostic.set("action.kind must be a string", .{});
        return error.InvalidConfig;
    };
    defer source_namespace.pop(state, 1);

    if (std.mem.eql(u8, kind, "scroll-pane")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
        const parsed_direction: source_namespace.action_mod.ScrollDirection = if (std.mem.eql(u8, direction, "up"))
            .up
        else if (std.mem.eql(u8, direction, "down"))
            .down
        else {
            diagnostic.set("scroll-pane direction must be up or down", .{});
            return error.InvalidConfig;
        };

        return .{ .scroll_pane = parsed_direction };
    }

    if (std.mem.eql(u8, kind, "split-pane")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
        const parsed_direction: source_namespace.action_mod.Direction = if (std.mem.eql(u8, direction, "left"))
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
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "index" }, .path = "action" }, diagnostic);
        const one_based = try source_namespace.requiredIntegerField(state, .{ .index = absolute, .name = "index" }, diagnostic);
        if (one_based <= 0 or one_based > 256) {
            diagnostic.set("select-tab index must be in 1..256", .{});
            return error.InvalidConfig;
        }
        return .{ .select_tab = @intCast(one_based - 1) };
    }
    if (std.mem.eql(u8, kind, "select-workspace")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "index" }, .path = "action" }, diagnostic);
        const one_based = try source_namespace.requiredIntegerField(state, .{ .index = absolute, .name = "index" }, diagnostic);
        if (one_based <= 0 or one_based > 256) {
            diagnostic.set("select-workspace index must be in 1..256", .{});
            return error.InvalidConfig;
        }
        return .{ .select_workspace = @intCast(one_based - 1) };
    }
    if (std.mem.eql(u8, kind, "select-tab-offset")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "offset" }, .path = "action" }, diagnostic);
        const offset = try source_namespace.requiredIntegerField(state, .{ .index = absolute, .name = "offset" }, diagnostic);
        if (offset < std.math.minInt(i8) or offset > std.math.maxInt(i8)) {
            diagnostic.set("select-tab-offset does not fit in i8", .{});
            return error.InvalidConfig;
        }
        return .{ .select_tab_offset = @intCast(offset) };
    }
    if (std.mem.eql(u8, kind, "move-tab")) {
        try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try source_namespace.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "command", "label" },
            .path = "action",
        }, diagnostic);
        _ = lua.lua_getfield(state, absolute, "command");
        defer source_namespace.pop(state, 1);
        if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
            diagnostic.set("command-tab action needs a command array", .{});
            return error.InvalidConfig;
        }
        const command_table = lua.lua_absindex(state, -1);
        const count = lua.lua_rawlen(state, command_table);
        if (count == 0 or count > source_namespace.action_mod.CommandTab.max_arguments) {
            diagnostic.set("command-tab command must contain 1..{d} arguments", .{source_namespace.action_mod.CommandTab.max_arguments});
            return error.InvalidConfig;
        }
        try source_namespace.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "command-tab command" }, diagnostic);
        var argument_storage: [source_namespace.action_mod.CommandTab.max_arguments][]const u8 = undefined;
        for (1..count + 1) |item| {
            _ = lua.lua_rawgeti(state, command_table, @intCast(item));
            defer source_namespace.pop(state, 1);
            var len: usize = 0;
            var text: []const u8 = "";
            if (lua.lua_type(state, -1) == lua.LUA_TSTRING) {
                if (lua.lua_tolstring(state, -1, &len)) |raw| {
                    text = raw[0..len];
                }
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
            if (lua.lua_tolstring(state, -1, &len)) |raw| {
                label = raw[0..len];
            }
        }
        defer source_namespace.pop(state, 1);
        return .{ .command_tab = source_namespace.action_mod.CommandTab.init(argument_storage[0..count], label) catch {
            diagnostic.set("command-tab command or label is invalid or too long", .{});
            return error.InvalidConfig;
        } };
    }
    if (std.mem.eql(u8, kind, "notification")) {
        try source_namespace.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{
                "kind",
                "title",
                "body",
                "level",
                "duration_ms",
                "pane_id",
                "tab_id",
                "workspace_id",
            },
            .path = "action",
        }, diagnostic);
        const title = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "title" }, diagnostic);
        const body = try source_namespace.optionalStringField(state, .{ .index = absolute, .name = "body", .default = "" }, diagnostic);
        const level_name = try source_namespace.optionalStringField(state, .{ .index = absolute, .name = "level", .default = "info" }, diagnostic);
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
        const duration = try source_namespace.optionalIntegerField(state, .{
            .index = absolute,
            .name = "duration_ms",
            .default = core.schema.default_notification_duration_ms,
        }, diagnostic);
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
        if (try source_namespace.optionalPositiveId(state, .{ .index = absolute, .name = "pane_id" }, diagnostic)) |raw| {
            target = .{ .pane = core.schema.id.pane(raw) catch {
                diagnostic.set("notification pane_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try source_namespace.optionalPositiveId(state, .{ .index = absolute, .name = "tab_id" }, diagnostic)) |raw| {
            target = .{ .tab = core.schema.id.tab(raw) catch {
                diagnostic.set("notification tab_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try source_namespace.optionalPositiveId(state, .{ .index = absolute, .name = "workspace_id" }, diagnostic)) |raw| {
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
        return .{ .notification = source_namespace.action_mod.Notification.init(.{
            .level = level,
            .duration_ms = @intCast(duration),
            .target = target,
            .title = title,
            .message = body,
        }) catch {
            diagnostic.set("notification title or body is invalid or too long", .{});
            return error.InvalidConfig;
        } };
    }
    if (std.mem.eql(u8, kind, "plugin")) {
        try source_namespace.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "plugin", "action" },
            .path = "action",
        }, diagnostic);
        const plugin_name = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "plugin" }, diagnostic);
        const action_name = try source_namespace.requiredStringField(state, .{ .index = absolute, .name = "action" }, diagnostic);
        return .{ .plugin = .{
            .plugin = core.plugin.stableId(plugin_name),
            .action = core.plugin.stableId(action_name),
        } };
    }
    const action = source_namespace.action_mod.Action.parse(kind) catch {
        diagnostic.set("unknown action kind '{s}'", .{kind});
        return error.InvalidConfig;
    };
    try source_namespace.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"kind"}, .path = "action" }, diagnostic);
    return action;
}
