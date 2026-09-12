const std = @import("std");
const VmType = @import("telar-lua").Vm;
const SnapshotType = @import("Snapshot.zig");
const config_model = @import("model.zig");
const Callback = @import("Callback.zig");
const BarCallback = @import("BarCallback.zig");
const StateType = @import("State.zig");
const generation_support = @import("generation_support.zig");
const LoadContext = @import("LoadContext.zig");
const SourceInput = @import("SourceInput.zig");
const LimitsType = @import("Limits.zig");
const lua_api = @import("lua-api");
const FileInput = @import("FileInput.zig");
const PluginSpecType = @import("PluginSpec.zig");
const CallbackInvocation = @import("CallbackInvocation.zig");
const DiagnosticType = @import("Diagnostic.zig");
const EffectBatchType = @import("EffectBatch.zig");
const InputDecisionType = @import("effects.zig").InputDecision;
const BarInvocationType = @import("BarInvocation.zig");
const ContentType = @import("../bars/Content.zig");
const default_callback_instruction_limit_module = @import("telar-lua").default_callback_instruction_limit;
const default_callback_deadline_ns_module = @import("telar-lua").default_callback_deadline_ns;
const bar_values = @import("bar_values.zig");
const CallbackPreparation = @import("CallbackPreparation.zig");
const lua_value = @import("lua_value.zig");
const max_callback_effects_module = @import("effects.zig").max_callback_effects;
const ActionType = @import("../input/action.zig").Action;
const open_module = @import("telar-lua").open;
const plugins_config = @import("plugins.zig");
const commands_config = @import("commands.zig");
const session_config = @import("session.zig");
const agents_config = @import("agents.zig");
const history_config = @import("history.zig");
const proxy_config = @import("proxy.zig");
const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
const client_history_config = @import("client_history.zig");
const theme_config = @import("theme.zig");
const ThemeType = @import("../layout/icons.zig").Theme;
const notifications_config = @import("notifications.zig");
const SourceType = @import("../bars/model.zig").Source;
const min_command_timeout_ms_module = @import("../bars/model.zig").min_command_timeout_ms;
const max_command_timeout_ms_module = @import("../bars/model.zig").max_command_timeout_ms;
const CommandType = @import("../bars/BarCommand.zig");
const max_command_args_module = @import("../bars/model.zig").max_command_args;
const CallbackRefType = @import("../bars/CallbackRef.zig");
const parseKey_module = @import("../input/chord.zig").parseKey;
const SidebarRenderingType = @import("sidebar_rendering.zig").SidebarRendering;
const BindingInput = @import("BindingInput.zig");
const ParsedBinding = @import("ParsedBinding.zig");
const KeyType = @import("../input/Key.zig");
const ActionInput = @import("ActionInput.zig");
const ClientInputCallbackRefCallbackRef = @import("../input/CallbackRef.zig");
const ScrollDirectionType = @import("../input/action.zig").ScrollDirection;
const DirectionType = @import("../input/action.zig").Direction;
const CommandTabType = @import("../input/CommandTab.zig");
const NotificationLevelType = @import("telar-core").NotificationLevel;
const default_notification_duration_ms_module = @import("telar-core").default_notification_duration_ms;
const min_notification_duration_ms_module = @import("telar-core").min_notification_duration_ms;
const max_notification_duration_ms_module = @import("telar-core").max_notification_duration_ms;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const pane_module = @import("telar-core").pane;
const tab_module = @import("telar-core").tab;
const workspace_module = @import("telar-core").workspace;
const NotificationType = @import("../input/Notification.zig");
const stableId_module = @import("telar-core").stableId;
const Generation = @This();

gpa: std.mem.Allocator,
number: u64,
vm: *VmType,
snapshot: SnapshotType = .{},
callbacks: [config_model.max_bindings]Callback = undefined,
callback_count: u16 = 0,
bar_callbacks: [config_model.max_bar_callbacks]BarCallback = undefined,
bar_callback_count: u8 = 0,
modules: StateType,
profile_bytes: [generation_support.max_profile_name_bytes]u8 = undefined,
profile_len: u8 = 0,

/// Compiles configuration source within the supplied loading environment.
/// For example: `Generation.loadSource(context, .{ .source = bytes, .source_name = "@config.lua", .number = 1 })`.
pub fn loadSource(context: LoadContext, spec: SourceInput) !*Generation {
    if (spec.profile) |name| {
        if (!generation_support.validProfileName(name)) {
            context.diagnostic.set("invalid profile name '{s}'", .{name});
            return error.InvalidProfileName;
        }
    }
    const generation = try context.gpa.create(Generation);
    errdefer context.gpa.destroy(generation);
    generation.* = .{
        .gpa = context.gpa,
        .number = spec.number,
        .vm = try VmType.init(context.io, .{
            .memory = config_model.default_memory_limit,
            .instructions = config_model.default_load_instruction_limit,
            .deadline_after_ns = (LimitsType{}).deadline_after_ns,
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
    generation.vm.resetBudget(config_model.default_load_instruction_limit, 100 * std.time.ns_per_ms);
    generation.vm.execute(.{ .source = generation_support.bootstrap, .name = "@telar/bootstrap.lua", .results = 0 }) catch |err| {
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
    lua_api.c.lua_settop(generation.vm.state, 0);
    return generation;
}

/// Reads and compiles one configuration file.
/// For example: `Generation.loadFile(context, .{ .path = "config.lua", .number = 1 })`.
pub fn loadFile(context: LoadContext, spec: FileInput) !*Generation {
    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path_len = std.Io.Dir.cwd().realPathFile(context.io, spec.path, &real_path_buffer) catch |err| {
        context.diagnostic.set("cannot resolve config '{s}': {s}", .{ spec.path, @errorName(err) });
        return err;
    };
    const real_path = real_path_buffer[0..real_path_len];
    const source = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        real_path,
        context.gpa,
        .limited(generation_support.max_config_bytes),
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

pub fn watchFingerprint(generation: *const Generation, io: std.Io, config_path: []const u8) i128 {
    return generation.modules.watchFingerprint(io, config_path);
}

pub fn configDir(generation: *const Generation) []const u8 {
    return generation.modules.configDir();
}

pub fn pluginSlice(generation: *const Generation) []const PluginSpecType {
    return generation.snapshot.plugins[0..generation.snapshot.plugin_count];
}

fn installRequire(generation: *Generation) void {
    return generation.modules.installRequire();
}

/// Runs an action callback against one immutable client snapshot.
/// For example: `generation.invokeCallback(.{ .reference = callback, .context = snapshot }, diagnostic)`.
pub fn invokeCallback(generation: *Generation, invocation: CallbackInvocation, diagnostic: *DiagnosticType) !EffectBatchType {
    const callback = try generation.prepareCallback(.{ .invocation = invocation, .expression = false }, diagnostic);
    _ = callback;
    const state = generation.vm.state;
    defer lua_api.c.lua_settop(state, 0);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua callback failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return generation.parseEffectBatch(-1, diagnostic);
}

/// Runs an input expression against one immutable client snapshot.
/// For example: `generation.invokeExpression(.{ .reference = expression, .context = snapshot }, diagnostic)`.
pub fn invokeExpression(generation: *Generation, invocation: CallbackInvocation, diagnostic: *DiagnosticType) !InputDecisionType {
    const callback = try generation.prepareCallback(.{ .invocation = invocation, .expression = true }, diagnostic);
    const state = generation.vm.state;
    defer lua_api.c.lua_settop(state, 0);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua expression failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return generation_support.parseInputDecision(state, .{ .index = -1, .callback = callback }, diagnostic);
}

pub fn invokeBar(generation: *Generation, invocation: BarInvocationType, diagnostic: *DiagnosticType) !ContentType {
    const reference = invocation.reference;
    if (reference.generation != generation.number or reference.id >= generation.bar_callback_count) {
        diagnostic.set("bar callback belongs to an obsolete configuration generation", .{});
        return error.StaleBarCallback;
    }

    const state = generation.vm.state;
    lua_api.c.lua_settop(state, 0);
    defer lua_api.c.lua_settop(state, 0);
    generation.vm.resetBudget(default_callback_instruction_limit_module, default_callback_deadline_ns_module);
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, generation.bar_callbacks[reference.id].registry_ref);
    generation_support.pushReadonlyBarContext(state, invocation.context);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua bar callback failed: {s}", .{generation.vm.errorMessage()});
        return error.LuaBarCallbackFailed;
    }

    return bar_values.parseBarContent(state, -1, diagnostic);
}

fn prepareCallback(generation: *Generation, preparation: CallbackPreparation, diagnostic: *DiagnosticType) !*const Callback {
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
    lua_api.c.lua_settop(state, 0);
    generation.vm.resetBudget(
        default_callback_instruction_limit_module,
        default_callback_deadline_ns_module,
    );
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, callback.registry_ref);
    generation_support.pushReadonlyContext(state, preparation.invocation.context);
    return callback;
}

fn parseEffectBatch(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !EffectBatchType {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("Lua callback must return an action or an array of actions", .{});
        return error.InvalidCallbackResult;
    }
    var batch: EffectBatchType = .{};
    _ = lua_api.c.lua_getfield(state, absolute, "kind");
    const single = lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL;
    lua_value.pop(state, 1);
    if (single) {
        batch.items[0] = try generation.parseReturnedAction(absolute, diagnostic);
        batch.len = 1;
        return batch;
    }
    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > max_callback_effects_module) {
        diagnostic.set("Lua callback exceeds {d} effects", .{max_callback_effects_module});
        return error.InvalidCallbackResult;
    }
    for (0..count) |effect_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(effect_index + 1));
        batch.items[effect_index] = generation.parseReturnedAction(-1, diagnostic) catch |err| {
            lua_value.pop(state, 1);
            return err;
        };
        lua_value.pop(state, 1);
    }
    batch.len = @intCast(count);
    return batch;
}

fn parseReturnedAction(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !ActionType {
    if (lua_api.c.lua_type(generation.vm.state, index) == lua_api.c.LUA_TFUNCTION) {
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
    try open_module(generation.vm.state);
}

fn parseSnapshot(generation: *Generation, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.lua must return a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{ .index = -1, .allowed = &.{ "api_version", "client", "runtime", "plugins", "profiles" }, .path = "config" }, diagnostic);

    _ = lua_api.c.lua_getfield(state, -1, "api_version");
    const version = lua_value.integer(state, -1) orelse {
        lua_value.pop(state, 1);
        diagnostic.set("config.api_version must be an integer", .{});
        return error.InvalidConfig;
    };
    lua_value.pop(state, 1);
    if (version != generation_support.api_version) {
        diagnostic.set(
            "config.api_version is {d}; this Telar accepts {d}",
            .{ version, generation_support.api_version },
        );
        return error.IncompatibleConfigApi;
    }

    _ = lua_api.c.lua_getfield(state, -1, "plugins");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try plugins_config.parse(state, &generation.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "client");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseClient(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "runtime");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseRuntime(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "profiles");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        if (generation.profile_len != 0) {
            diagnostic.set("profile '{s}' is not defined", .{generation.profile_bytes[0..generation.profile_len]});
            return error.UnknownProfile;
        }
        return;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.profiles must be a table", .{});
        return error.InvalidConfig;
    }
    try generation.parseProfiles(-1, diagnostic);
}

fn parseProfile(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "client", "runtime", "plugins" }, .path = "profile" }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "plugins");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try plugins_config.parse(state, &generation.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "client");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseClient(-1, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "runtime");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseRuntime(-1, diagnostic);
    }
    lua_value.pop(state, 1);
}

fn parseProfiles(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    const base_snapshot = generation.snapshot;
    var selected_snapshot: ?SnapshotType = null;
    const selected_name = generation.profile_bytes[0..generation.profile_len];
    lua_api.c.lua_pushnil(state);
    while (lua_api.c.lua_next(state, absolute) != 0) {
        const name = lua_value.string(state, -2) orelse {
            lua_value.pop(state, 2);
            diagnostic.set("config.profiles contains a non-string name", .{});
            return error.InvalidConfig;
        };
        if (!generation_support.validProfileName(name)) {
            diagnostic.set("invalid profile name '{s}'", .{name});
            lua_value.pop(state, 2);
            return error.InvalidConfig;
        }
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
            diagnostic.set("profile '{s}' must be a table", .{name});
            lua_value.pop(state, 2);
            return error.InvalidConfig;
        }
        generation.snapshot = base_snapshot;
        generation.parseProfile(-1, diagnostic) catch |err| {
            lua_value.pop(state, 2);
            return err;
        };
        if (generation.profile_len != 0 and std.mem.eql(u8, name, selected_name)) {
            selected_snapshot = generation.snapshot;
        }
        lua_value.pop(state, 1);
    }
    generation.snapshot = if (generation.profile_len == 0)
        base_snapshot
    else
        selected_snapshot orelse {
            diagnostic.set("profile '{s}' is not defined", .{selected_name});
            return error.UnknownProfile;
        };
}

fn parseRuntime(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "graphics", "history", "proxy", "agent_descriptions", "engine", "agents", "session" },
        .path = "config.runtime",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "engine");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try commands_config.parseEngine(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "session");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try session_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "agents");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try agents_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "history");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try history_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "proxy");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try proxy_config.parse(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "agent_descriptions");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try commands_config.parseAgentDescriptions(state, &generation.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "graphics");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime.graphics must be a table", .{});
        return error.InvalidConfig;
    }
    const graphics = lua_api.c.lua_absindex(state, -1);
    try lua_value.ensureOnlyFields(state, .{
        .index = graphics,
        .allowed = &.{ "pane_mib", "global_mib" },
        .path = "config.runtime.graphics",
    }, diagnostic);
    generation.snapshot.runtime.graphics_pane_bytes = try lua_value.optionalMebibytes(state, .{
        .index = graphics,
        .name = "pane_mib",
        .default = generation.snapshot.runtime.graphics_pane_bytes,
    }, diagnostic);
    generation.snapshot.runtime.graphics_global_bytes = try lua_value.optionalMebibytes(state, .{
        .index = graphics,
        .name = "global_mib",
        .default = generation.snapshot.runtime.graphics_global_bytes,
    }, diagnostic);
    const runtime = generation.snapshot.runtime;
    if (runtime.graphics_pane_bytes < 2 * 1024 * 1024 or
        runtime.graphics_pane_bytes > max_image_bytes_per_pane_module or
        runtime.graphics_global_bytes < runtime.graphics_pane_bytes or
        runtime.graphics_global_bytes > max_image_bytes_global_module)
    {
        diagnostic.set("runtime graphics limits are outside Telar's safe bounds", .{});
        return error.InvalidConfig;
    }
}

fn parseClient(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "prefix", "theme", "icons", "sidebar", "pane_gaps", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "history" },
        .path = "config.client",
    }, diagnostic);

    _ = lua_api.c.lua_getfield(state, absolute, "prefix");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parsePrefix(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "history");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try client_history_config.parse(state, &generation.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "theme");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        generation.snapshot.theme = try theme_config.parse(state, -1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "icons");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const value = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.icons must be a string", .{});
            return error.InvalidConfig;
        };
        generation.snapshot.icon_theme = ThemeType.parse(value) catch {
            diagnostic.set("unknown config.client.icons: {s}", .{value});
            lua_value.pop(state, 1);
            return error.InvalidConfig;
        };
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "sidebar");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseSidebar(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "pane_gaps");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.pane_gaps must be a boolean", .{});
            return error.InvalidConfig;
        }
        generation.snapshot.pane_gaps = lua_api.c.lua_toboolean(state, -1) != 0;
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "window_title");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TSTRING) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.window_title must be a string", .{});
            return error.InvalidConfig;
        }

        var len: usize = 0;
        const template: []const u8 = if (lua_api.c.lua_tolstring(state, -1, &len)) |raw| raw[0..len] else "";
        if (template.len > config_model.max_window_title_bytes or !std.unicode.utf8ValidateSlice(template) or generation_support.hasControlBytes(template)) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.window_title must be printable UTF-8 of at most {d} bytes", .{config_model.max_window_title_bytes});
            return error.InvalidConfig;
        }

        @memcpy(generation.snapshot.window_title_bytes[0..template.len], template);
        generation.snapshot.window_title_len = @intCast(template.len);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "sound");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseSound(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "notifications");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try notifications_config.parse(state, &generation.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "appearance");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try theme_config.parseAppearance(state, &generation.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "input");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseInputOptions(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "keybindings");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseBindings(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "bars");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseBars(-1, diagnostic);
    }
    lua_value.pop(state, 1);
}

fn parseBars(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bottom", "top" }, .path = "config.client.bars" }, diagnostic);

    _ = lua_api.c.lua_getfield(state, absolute, "bottom");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseBottomBar(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "top");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try generation.parseTopBar(-1, diagnostic);
    }
    lua_value.pop(state, 1);
}

fn parseBottomBar(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars.bottom must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "left", "center", "right" }, .path = "config.client.bars.bottom" }, diagnostic);
    var parsed: [3]SourceType = .{ .empty, .empty, .empty };
    inline for (.{ "left", "center", "right" }, 0..) |field, source_index| {
        _ = lua_api.c.lua_getfield(state, absolute, field);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            parsed[source_index] = try generation.parseBarSource(-1, diagnostic);
        }
        lua_value.pop(state, 1);
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

fn parseTopBar(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars.top must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"right"}, .path = "config.client.bars.top" }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "right");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
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

fn parseBarSource(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !SourceType {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("bar position must contain a telar.bar value", .{});
        return error.InvalidConfig;
    }

    _ = lua_api.c.lua_getfield(state, absolute, "bar_kind");
    const kind = lua_value.string(state, -1) orelse {
        lua_value.pop(state, 1);
        diagnostic.set("bar position must contain a telar.bar value", .{});
        return error.InvalidConfig;
    };
    lua_value.pop(state, 1);

    if (std.mem.eql(u8, kind, "tabs")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"bar_kind"}, .path = "bar tabs" }, diagnostic);
        return .tabs;
    }
    if (std.mem.eql(u8, kind, "metrics")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"bar_kind"}, .path = "bar metrics" }, diagnostic);
        return .metrics;
    }
    if (std.mem.eql(u8, kind, "static")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "value" }, .path = "bar static block" }, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "value");
        defer lua_value.pop(state, 1);
        return .{ .static = try bar_values.parseBarContent(state, -1, diagnostic) };
    }
    if (std.mem.eql(u8, kind, "dynamic")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "every_ms", "render" }, .path = "bar dynamic block" }, diagnostic);
        const interval_ns = try bar_values.parseBarInterval(state, absolute, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "render");
        defer lua_value.pop(state, 1);
        const callback = try generation.registerBarCallback(-1, diagnostic);
        return .{ .dynamic = .{ .callback = callback, .interval_ns = interval_ns } };
    }
    if (std.mem.eql(u8, kind, "command")) {
        return generation.parseBarCommand(absolute, diagnostic);
    }

    diagnostic.set("unknown bar value '{s}'", .{kind});
    return error.InvalidConfig;
}

fn parseBarCommand(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !SourceType {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "bar_kind", "command", "every_ms", "timeout_ms", "render" },
        .path = "bar command block",
    }, diagnostic);

    const interval_ns = try bar_values.parseBarInterval(state, absolute, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "timeout_ms");
    const timeout_value = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        2_000
    else
        lua_value.integer(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("bar command timeout_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    lua_value.pop(state, 1);
    if (timeout_value < min_command_timeout_ms_module or timeout_value > max_command_timeout_ms_module) {
        diagnostic.set(
            "bar command timeout_ms must be in {d}..{d}",
            .{ min_command_timeout_ms_module, max_command_timeout_ms_module },
        );
        return error.InvalidConfig;
    }

    var command: CommandType = .{
        .generation = generation.number,
        .interval_ns = interval_ns,
        .timeout_ms = @intCast(timeout_value),
    };
    _ = lua_api.c.lua_getfield(state, absolute, "command");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        lua_value.pop(state, 1);
        diagnostic.set("bar command must be an array", .{});
        return error.InvalidConfig;
    }
    const command_table = lua_api.c.lua_absindex(state, -1);
    const count = lua_api.c.lua_rawlen(state, command_table);
    if (count == 0 or count > max_command_args_module) {
        lua_value.pop(state, 1);
        diagnostic.set("bar command must contain 1..{d} arguments", .{max_command_args_module});
        return error.InvalidConfig;
    }
    try lua_value.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "bar command" }, diagnostic);
    for (0..count) |argument_index| {
        _ = lua_api.c.lua_geti(state, command_table, @intCast(argument_index + 1));
        const argument_value = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 2);
            diagnostic.set("bar command argument {d} must be a string", .{argument_index + 1});
            return error.InvalidConfig;
        };
        command.appendArgument(argument_value) catch |err| {
            lua_value.pop(state, 2);
            diagnostic.set("invalid bar command: {s}", .{@errorName(err)});
            return error.InvalidConfig;
        };
        lua_value.pop(state, 1);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "render");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        command.render = try generation.registerBarCallback(-1, diagnostic);
    }

    return .{ .command = command };
}

fn registerBarCallback(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !CallbackRefType {
    const state = generation.vm.state;
    if (lua_api.c.lua_type(state, index) != lua_api.c.LUA_TFUNCTION) {
        diagnostic.set("bar render must be a Lua function", .{});
        return error.InvalidConfig;
    }
    if (generation.bar_callback_count == config_model.max_bar_callbacks) {
        diagnostic.set("configuration exceeds {d} bar callbacks", .{config_model.max_bar_callbacks});
        return error.InvalidConfig;
    }

    lua_api.c.lua_pushvalue(state, index);
    const registry_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    const id = generation.bar_callback_count;
    generation.bar_callbacks[id] = .{ .registry_ref = registry_ref };
    generation.bar_callback_count += 1;
    return .{ .generation = generation.number, .id = id };
}

fn parsePrefix(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const value = lua_value.string(generation.vm.state, index) orelse {
        diagnostic.set("config.client.prefix must be a string", .{});
        return error.InvalidConfig;
    };
    const prefix = parseKey_module(value) catch |err| {
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

fn parseInputOptions(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.input must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "escape_timeout_ms", "sequence_timeout_ms" },
        .path = "config.client.input",
    }, diagnostic);
    generation.snapshot.input_escape_timeout_ns = try lua_value.optionalMilliseconds(state, .{
        .index = absolute,
        .name = "escape_timeout_ms",
        .default_ns = generation.snapshot.input_escape_timeout_ns,
        .minimum_ms = 1,
        .maximum_ms = 1000,
    }, diagnostic);
    generation.snapshot.input_sequence_timeout_ns = try lua_value.optionalMilliseconds(state, .{
        .index = absolute,
        .name = "sequence_timeout_ms",
        .default_ns = generation.snapshot.input_sequence_timeout_ns,
        .minimum_ms = 10,
        .maximum_ms = 10_000,
    }, diagnostic);
}

fn parseSound(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.sound must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "enabled", "ready", "needs_input" },
        .path = "config.client.sound",
    }, diagnostic);
    inline for (.{ "enabled", "ready", "needs_input" }) |field| {
        _ = lua_api.c.lua_getfield(state, absolute, field);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
                lua_value.pop(state, 1);
                diagnostic.set("config.client.sound.{s} must be a boolean", .{field});
                return error.InvalidConfig;
            }
            @field(generation.snapshot.sound, field) = lua_api.c.lua_toboolean(state, -1) != 0;
        }
        lua_value.pop(state, 1);
    }
}

fn parseSidebar(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.sidebar must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "visible", "renderer" },
        .path = "config.client.sidebar",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "visible");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.sidebar.visible must be a boolean", .{});
            return error.InvalidConfig;
        }
        generation.snapshot.sidebar_visible = lua_api.c.lua_toboolean(state, -1) != 0;
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "renderer");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const value = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.sidebar.renderer must be a string", .{});
            return error.InvalidConfig;
        };
        generation.snapshot.sidebar_rendering = SidebarRenderingType.parse(value) catch {
            diagnostic.set("unknown sidebar renderer '{s}'", .{value});
            lua_value.pop(state, 1);
            return error.InvalidConfig;
        };
    }
    lua_value.pop(state, 1);
}

fn parseBindings(generation: *Generation, index: c_int, diagnostic: *DiagnosticType) !void {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.keybindings must be an array", .{});
        return error.InvalidConfig;
    }
    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > config_model.max_bindings) {
        diagnostic.set("config.client.keybindings exceeds {d} entries", .{config_model.max_bindings});
        return error.InvalidConfig;
    }
    generation.snapshot.binding_count = 0;
    for (0..count) |binding_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(binding_index + 1));
        const parsed = generation.parseBinding(.{ .index = -1, .position = binding_index }, diagnostic) catch |err| {
            lua_value.pop(state, 1);
            return err;
        };
        generation.snapshot.bindings[binding_index] = parsed.binding;
        generation.snapshot.bindings_prefixed[binding_index] = parsed.prefixed;
        lua_value.pop(state, 1);
    }
    generation.snapshot.binding_count = @intCast(count);
}

fn parseBinding(generation: *Generation, binding_input: BindingInput, diagnostic: *DiagnosticType) !ParsedBinding {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, binding_input.index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("keybinding {d} must be a telar.bind value", .{binding_input.position + 1});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "keys", "action", "expression", "prefixed" },
        .path = "keybinding",
    }, diagnostic);

    _ = lua_api.c.lua_getfield(state, absolute, "prefixed");
    const prefixed = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TBOOLEAN)
        lua_api.c.lua_toboolean(state, -1) != 0
    else {
        lua_value.pop(state, 1);
        diagnostic.set("keybinding {d}.prefixed must be a boolean", .{binding_input.position + 1});
        return error.InvalidConfig;
    };
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "keys");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        lua_value.pop(state, 1);
        diagnostic.set("keybinding {d}.keys must be an array", .{binding_input.position + 1});
        return error.InvalidConfig;
    }
    const key_count = lua_api.c.lua_rawlen(state, -1);
    const key_limit: usize = if (prefixed) generation_support.max_binding_suffix_keys else config_model.max_binding_keys;
    if (key_count == 0 or key_count > key_limit) {
        lua_value.pop(state, 1);
        diagnostic.set(
            "keybinding {d}.keys must contain 1..{d} keys",
            .{ binding_input.position + 1, key_limit },
        );
        return error.InvalidConfig;
    }
    var keys: [config_model.max_binding_keys]KeyType = undefined;
    const key_offset: usize = @intFromBool(prefixed);
    if (prefixed) {
        keys[0] = generation.snapshot.prefix;
    }
    for (0..key_count) |key_index| {
        _ = lua_api.c.lua_geti(state, -1, @intCast(key_index + 1));
        const name = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 2);
            diagnostic.set(
                "keybinding {d}.keys[{d}] must be a string",
                .{ binding_input.position + 1, key_index + 1 },
            );
            return error.InvalidConfig;
        };
        keys[key_offset + key_index] = parseKey_module(name) catch |err| {
            lua_value.pop(state, 2);
            diagnostic.set(
                "invalid keybinding {d}: {s}",
                .{ binding_input.position + 1, @errorName(err) },
            );
            return error.InvalidConfig;
        };
        lua_value.pop(state, 1);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "expression");
    const expression = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        false
    else if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TBOOLEAN)
        lua_api.c.lua_toboolean(state, -1) != 0
    else {
        lua_value.pop(state, 1);
        diagnostic.set("keybinding {d}.expression must be a boolean", .{binding_input.position + 1});
        return error.InvalidConfig;
    };
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "action");
    const action = generation.parseAction(.{ .index = -1, .expression = expression }, diagnostic) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };
    lua_value.pop(state, 1);
    const total_key_count = key_offset + key_count;
    const binding = config_model.ConfiguredBinding.init(keys[0..total_key_count], action) catch |err| {
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

fn parseAction(generation: *Generation, action_input: ActionInput, diagnostic: *DiagnosticType) !ActionType {
    const state = generation.vm.state;
    const absolute = lua_api.c.lua_absindex(state, action_input.index);
    if (lua_api.c.lua_type(state, absolute) == lua_api.c.LUA_TFUNCTION) {
        if (generation.callback_count == config_model.max_bindings) {
            diagnostic.set("configuration exceeds {d} Lua callbacks", .{config_model.max_bindings});
            return error.InvalidConfig;
        }
        lua_api.c.lua_pushvalue(state, absolute);
        const registry_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
        const id = generation.callback_count;
        generation.callbacks[id] = .{
            .registry_ref = registry_ref,
            .expression = action_input.expression,
        };
        generation.callback_count += 1;
        const reference: ClientInputCallbackRefCallbackRef = .{
            .generation = generation.number,
            .id = id,
        };
        return if (action_input.expression)
            .{ .lua_expr = reference }
        else
            .{ .lua_callback = reference };
    }

    if (lua_value.string(state, absolute)) |name| {
        if (action_input.expression) {
            diagnostic.set("expression binding action must be a Lua function", .{});
            return error.InvalidConfig;
        }
        return ActionType.parse(name) catch {
            diagnostic.set("unknown action '{s}'", .{name});
            return error.InvalidConfig;
        };
    }

    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("keybinding action must be a string, action, or function", .{});
        return error.InvalidConfig;
    }
    if (action_input.expression) {
        diagnostic.set("expression binding action must be a Lua function", .{});
        return error.InvalidConfig;
    }

    _ = lua_api.c.lua_getfield(state, absolute, "kind");
    const kind = lua_value.string(state, -1) orelse {
        lua_value.pop(state, 1);
        diagnostic.set("action.kind must be a string", .{});
        return error.InvalidConfig;
    };
    defer lua_value.pop(state, 1);

    if (std.mem.eql(u8, kind, "scroll-pane")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
        const parsed_direction: ScrollDirectionType = if (std.mem.eql(u8, direction, "up"))
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
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
        const parsed_direction: DirectionType = if (std.mem.eql(u8, direction, "left"))
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
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "index" }, .path = "action" }, diagnostic);
        const one_based = try lua_value.requiredIntegerField(state, .{ .index = absolute, .name = "index" }, diagnostic);
        if (one_based <= 0 or one_based > 256) {
            diagnostic.set("select-tab index must be in 1..256", .{});
            return error.InvalidConfig;
        }
        return .{ .select_tab = @intCast(one_based - 1) };
    }
    if (std.mem.eql(u8, kind, "select-workspace")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "index" }, .path = "action" }, diagnostic);
        const one_based = try lua_value.requiredIntegerField(state, .{ .index = absolute, .name = "index" }, diagnostic);
        if (one_based <= 0 or one_based > 256) {
            diagnostic.set("select-workspace index must be in 1..256", .{});
            return error.InvalidConfig;
        }
        return .{ .select_workspace = @intCast(one_based - 1) };
    }
    if (std.mem.eql(u8, kind, "select-tab-offset")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "offset" }, .path = "action" }, diagnostic);
        const offset = try lua_value.requiredIntegerField(state, .{ .index = absolute, .name = "offset" }, diagnostic);
        if (offset < std.math.minInt(i8) or offset > std.math.maxInt(i8)) {
            diagnostic.set("select-tab-offset does not fit in i8", .{});
            return error.InvalidConfig;
        }
        return .{ .select_tab_offset = @intCast(offset) };
    }
    if (std.mem.eql(u8, kind, "move-tab")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "kind", "direction" }, .path = "action" }, diagnostic);
        const direction = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "direction" }, diagnostic);
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
        try lua_value.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "command", "label" },
            .path = "action",
        }, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "command");
        defer lua_value.pop(state, 1);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
            diagnostic.set("command-tab action needs a command array", .{});
            return error.InvalidConfig;
        }
        const command_table = lua_api.c.lua_absindex(state, -1);
        const count = lua_api.c.lua_rawlen(state, command_table);
        if (count == 0 or count > CommandTabType.max_arguments) {
            diagnostic.set("command-tab command must contain 1..{d} arguments", .{CommandTabType.max_arguments});
            return error.InvalidConfig;
        }
        try lua_value.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "command-tab command" }, diagnostic);
        var argument_storage: [CommandTabType.max_arguments][]const u8 = undefined;
        for (1..count + 1) |item| {
            _ = lua_api.c.lua_rawgeti(state, command_table, @intCast(item));
            defer lua_value.pop(state, 1);
            var len: usize = 0;
            var text: []const u8 = "";
            if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TSTRING) {
                if (lua_api.c.lua_tolstring(state, -1, &len)) |raw| {
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
        _ = lua_api.c.lua_getfield(state, absolute, "label");
        if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TSTRING) {
            var len: usize = 0;
            if (lua_api.c.lua_tolstring(state, -1, &len)) |raw| {
                label = raw[0..len];
            }
        }
        defer lua_value.pop(state, 1);
        return .{ .command_tab = CommandTabType.init(argument_storage[0..count], label) catch {
            diagnostic.set("command-tab command or label is invalid or too long", .{});
            return error.InvalidConfig;
        } };
    }
    if (std.mem.eql(u8, kind, "notification")) {
        try lua_value.ensureOnlyFields(state, .{
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
        const title = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "title" }, diagnostic);
        const body = try lua_value.optionalStringField(state, .{ .index = absolute, .name = "body", .default = "" }, diagnostic);
        const level_name = try lua_value.optionalStringField(state, .{ .index = absolute, .name = "level", .default = "info" }, diagnostic);
        const level: NotificationLevelType = if (std.mem.eql(u8, level_name, "info"))
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
        const duration = try lua_value.optionalIntegerField(state, .{
            .index = absolute,
            .name = "duration_ms",
            .default = default_notification_duration_ms_module,
        }, diagnostic);
        if (duration < min_notification_duration_ms_module or
            duration > max_notification_duration_ms_module)
        {
            diagnostic.set(
                "notification duration_ms must be in {d}..{d}",
                .{
                    min_notification_duration_ms_module,
                    max_notification_duration_ms_module,
                },
            );
            return error.InvalidConfig;
        }

        var target: NotificationTargetType = .none;
        var target_count: u8 = 0;
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "pane_id" }, diagnostic)) |raw| {
            target = .{ .pane = pane_module(raw) catch {
                diagnostic.set("notification pane_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "tab_id" }, diagnostic)) |raw| {
            target = .{ .tab = tab_module(raw) catch {
                diagnostic.set("notification tab_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "workspace_id" }, diagnostic)) |raw| {
            target = .{ .workspace = workspace_module(raw) catch {
                diagnostic.set("notification workspace_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (target_count > 1) {
            diagnostic.set("notification accepts only one click target", .{});
            return error.InvalidConfig;
        }
        return .{ .notification = NotificationType.init(.{
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
        try lua_value.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "plugin", "action" },
            .path = "action",
        }, diagnostic);
        const plugin_name = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "plugin" }, diagnostic);
        const action_name = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "action" }, diagnostic);
        return .{ .plugin = .{
            .plugin = stableId_module(plugin_name),
            .action = stableId_module(action_name),
        } };
    }
    const action = ActionType.parse(kind) catch {
        diagnostic.set("unknown action kind '{s}'", .{kind});
        return error.InvalidConfig;
    };
    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"kind"}, .path = "action" }, diagnostic);
    return action;
}
