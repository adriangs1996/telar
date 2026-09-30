const keyinput = @import("keyinput");
const lua = @import("telar-lua");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const Snapshot = @import("Snapshot.zig");
const Callback = @import("Callback.zig");
const State = @import("State.zig");
const generation_support = @import("generation_support.zig");

test {
    _ = @import("gui_config_test.zig");
    _ = @import("theme_test.zig");
}
const lua_api = @import("lua-api");
const BarCallbackContext = @import("BarCallbackContext.zig");
const bar_values = @import("bar_values.zig");
const component_values = @import("component_values.zig");
const pick_values = @import("pick_values.zig");
const lua_value = @import("lua_value.zig");
const plugins_config = @import("plugins.zig");
const commands_config = @import("commands.zig");
const session_config = @import("session.zig");
const agents_config = @import("agents.zig");
const history_config = @import("history.zig");
const proxy_config = @import("proxy.zig");
const client_history_config = @import("client_history.zig");
const ThemeParser = @import("ThemeParser.zig");
const notifications_config = @import("notifications.zig");
const GuiConfigParser = @import("GuiConfigParser.zig");
const UnreportedReaches = @import("UnreportedReaches.zig");
const CommandTabs = @import("CommandTabs.zig");
const default_bindings = @import("default_bindings.zig");
const Generation = @This();

gpa: std.mem.Allocator,
number: u64,
vm: *lua.Vm,
snapshot: Snapshot = .{},
callbacks: [data.config_values.max_bindings]Callback = undefined,
callback_count: u16 = 0,
bar_callbacks: [data.config_values.max_bar_callbacks]BarCallback = undefined,
bar_callback_count: u8 = 0,
modules: State,
profile_bytes: [generation_support.max_profile_name_bytes]u8 = undefined,
profile_len: u8 = 0,
/// Everything one render returns before it is fitted into its slot or
/// panel; reused by every render of this generation.
staged_content: *data.StagedContent,
/// Limits this generation reached that its client has not reported yet.
unreported: UnreportedReaches = .{},
/// Whether `client.panels` or `client.picks` held more entries than fit,
/// so an action may name one that was left out.
dropped: std.EnumSet(DroppedEntries) = .initEmpty(),

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
    const staged_content = try context.gpa.create(data.StagedContent);
    errdefer context.gpa.destroy(staged_content);
    staged_content.clear();
    generation.* = .{
        .gpa = context.gpa,
        .number = spec.number,
        .vm = try lua.Vm.init(context.io, context.gpa, .{}),
        .modules = undefined,
        .staged_content = staged_content,
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
    generation.vm.resetBudget(lua.default_load_instruction_limit, lua.default_load_deadline_ns);
    generation.vm.execute(.{ .source = generation_support.bootstrap, .name = "@telar/bootstrap.lua", .results = 0 }) catch |err| {
        context.diagnostic.set("failed to initialize telar Lua API: {s}", .{generation.vm.errorMessage()});
        return err;
    };
    generation.installJson();
    generation.installRequire();
    generation.vm.execute(.{ .source = spec.source, .name = spec.source_name, .results = 1 }) catch |err| {
        context.diagnostic.set("{s}", .{generation.vm.errorMessage()});
        return err;
    };
    generation.parseSnapshot(context.diagnostic) catch |err| return err;
    generation.checkKeymapRoom();
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

pub fn deinit(self: *Generation) void {
    self.vm.deinit();
    self.gpa.destroy(self.staged_content);
    self.gpa.destroy(self);
}

pub fn dependencyPath(self: *const Generation, index: usize) ?[]const u8 {
    return self.modules.dependencyPath(index);
}

pub fn watchFingerprint(self: *const Generation, io: std.Io, config_path: []const u8) i128 {
    return self.modules.watchFingerprint(io, config_path);
}

pub fn configDir(self: *const Generation) []const u8 {
    return self.modules.configDir();
}

pub fn pluginSlice(self: *const Generation) []const data.PluginSpec {
    return self.snapshot.plugins[0..self.snapshot.plugin_count];
}

/// Leaves the keymap limit for the client to report when the configured
/// bindings and the defaults they keep do not all fit; the router then
/// keeps the configured ones and the defaults that fit.
fn checkKeymapRoom(self: *Generation) void {
    const extra = default_bindings.surplus(self.snapshot.prefix, self.snapshot.bindingSlice()) catch return;
    if (extra == 0) {
        return;
    }

    self.unreported.add(.{
        .limit = data.config_values.bindings_limit,
        .requested = data.config_values.max_bindings + extra,
    });
}

/// Adds `telar.json.decode` for render callbacks that read command output.
fn installJson(self: *Generation) void {
    const state = self.vm.state;
    _ = lua_api.c.lua_getglobal(state, "telar");
    lua.json.install(state);
    lua_api.c.lua_settop(state, 0);
}

fn installRequire(self: *Generation) void {
    return self.modules.installRequire();
}

/// Runs an action callback against one immutable client snapshot.
/// For example: `generation.invokeCallback(.{ .reference = callback, .context = snapshot }, diagnostic)`.
pub fn invokeCallback(self: *Generation, invocation: CallbackInvocation, diagnostic: *data.Diagnostic) !data.EffectBatch {
    const callback = try self.prepareCallback(.{ .invocation = invocation, .expression = false }, diagnostic);
    _ = callback;
    const state = self.vm.state;
    defer lua_api.c.lua_settop(state, 0);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua callback failed: {s}", .{self.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return self.parseEffectBatch(-1, diagnostic);
}

/// Runs an input expression against one immutable client snapshot.
/// For example: `generation.invokeExpression(.{ .reference = expression, .context = snapshot }, diagnostic)`.
pub fn invokeExpression(self: *Generation, invocation: CallbackInvocation, diagnostic: *data.Diagnostic) !data.InputDecision {
    const callback = try self.prepareCallback(.{ .invocation = invocation, .expression = true }, diagnostic);
    const state = self.vm.state;
    defer lua_api.c.lua_settop(state, 0);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua expression failed: {s}", .{self.vm.errorMessage()});
        return error.LuaCallbackFailed;
    }
    return generation_support.parseInputDecision(state, .{ .index = -1, .callback = callback }, diagnostic);
}

/// Runs a bar or panel render callback and parses the components it returns
/// into `content`, a `data.Content` or a `data.PanelContent`.
/// Example: `try generation.invokeBar(.{ .reference = ref, .context = context }, &content, diagnostic);`
pub fn invokeBar(self: *Generation, invocation: BarInvocation, content: anytype, diagnostic: *data.Diagnostic) !void {
    const reference = invocation.reference;
    if (reference.generation != self.number or reference.id >= self.bar_callback_count) {
        diagnostic.set("bar callback belongs to an obsolete configuration generation", .{});
        return error.StaleBarCallback;
    }

    const state = self.vm.state;
    lua_api.c.lua_settop(state, 0);
    defer lua_api.c.lua_settop(state, 0);
    self.vm.resetBudget(lua.default_render_instruction_limit, lua.default_callback_deadline_ns);
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, self.bar_callbacks[reference.id].registry_ref);
    generation_support.pushReadonlyBarContext(state, invocation.context);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        diagnostic.set("Lua bar callback failed: {s}", .{self.vm.errorMessage()});
        return error.LuaBarCallbackFailed;
    }

    try component_values.parse(self, content, .{
        .index = -1,
        .surface = invocation.surface,
    }, diagnostic);
}

/// Lists a pick's options into `items`: its `items` table as written, or
/// what its `items` function returns for the context, whose `output` holds
/// the list command's output.
/// Example: `try generation.invokePick(.{ .reference = ref, .context = context }, &items, diagnostic);`
pub fn invokePick(self: *Generation, invocation: BarInvocation, items: *data.PickItems, diagnostic: *data.Diagnostic) !void {
    const reference = invocation.reference;
    if (reference.generation != self.number or reference.id >= self.bar_callback_count) {
        diagnostic.set("pick items belong to an obsolete configuration generation", .{});
        return error.StaleBarCallback;
    }

    const state = self.vm.state;
    lua_api.c.lua_settop(state, 0);
    defer lua_api.c.lua_settop(state, 0);
    self.vm.resetBudget(lua.default_render_instruction_limit, lua.default_callback_deadline_ns);
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, self.bar_callbacks[reference.id].registry_ref);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TFUNCTION) {
        generation_support.pushReadonlyBarContext(state, invocation.context);
        if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
            diagnostic.set("Lua pick items failed: {s}", .{self.vm.errorMessage()});
            return error.LuaBarCallbackFailed;
        }
    }

    try pick_values.parse(state, -1, items, diagnostic);
}

fn prepareCallback(self: *Generation, preparation: CallbackPreparation, diagnostic: *data.Diagnostic) !*const Callback {
    const reference = preparation.invocation.reference;
    if (reference.generation != self.number or reference.id >= self.callback_count) {
        diagnostic.set("callback belongs to an obsolete configuration generation", .{});
        return error.StaleCallback;
    }
    const callback = &self.callbacks[reference.id];
    if (callback.expression != preparation.expression) {
        diagnostic.set("callback kind does not match its binding", .{});
        return error.InvalidCallbackKind;
    }
    const state = self.vm.state;
    lua_api.c.lua_settop(state, 0);
    self.vm.resetBudget(
        lua.default_callback_instruction_limit,
        lua.default_callback_deadline_ns,
    );
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, callback.registry_ref);
    generation_support.pushReadonlyContext(state, preparation.invocation.context);
    return callback;
}

fn parseEffectBatch(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.EffectBatch {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("Lua callback must return an action or an array of actions", .{});
        return error.InvalidCallbackResult;
    }
    var batch: data.EffectBatch = .{};
    _ = lua_api.c.lua_getfield(state, absolute, "kind");
    const single = lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL;
    lua_value.pop(state, 1);
    if (single) {
        batch.items[0] = try self.parseReturnedAction(absolute, diagnostic);
        batch.len = 1;
        return batch;
    }
    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > data.effects.max_callback_effects) {
        diagnostic.set("Lua callback exceeds {d} effects", .{data.effects.max_callback_effects});
        return error.InvalidCallbackResult;
    }
    for (0..count) |effect_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(effect_index + 1));
        batch.items[effect_index] = self.parseReturnedAction(-1, diagnostic) catch |err| {
            lua_value.pop(state, 1);
            return err;
        };
        lua_value.pop(state, 1);
    }
    batch.len = @intCast(count);
    return batch;
}

/// Parses the action a component runs when clicked. Like a callback's
/// returned actions, it cannot be another Lua function.
/// Example: `const action = try generation.parseComponentAction(-1, diagnostic);`
pub fn parseComponentAction(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.Action {
    return self.parseReturnedAction(index, diagnostic);
}

fn parseReturnedAction(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.Action {
    if (lua_api.c.lua_type(self.vm.state, index) == lua_api.c.LUA_TFUNCTION) {
        diagnostic.set("a callback cannot return another callback", .{});
        return error.InvalidCallbackResult;
    }
    const action = self.parseAction(.{ .index = index, .expression = false }, diagnostic) catch
        return error.InvalidCallbackResult;
    return switch (action) {
        .lua_callback, .lua_expr => error.InvalidCallbackResult,
        else => action,
    };
}

fn openEnvironment(self: *Generation) !void {
    try lua.open(self.vm.state);
}

fn parseSnapshot(self: *Generation, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.lua must return a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{ .index = -1, .allowed = &.{ "api_version", "theme", "client", "gui", "runtime", "plugins", "profiles" }, .path = "config" }, diagnostic);

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
        try plugins_config.parse(state, &self.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    const theme_parser: ThemeParser = .{ .state = state, .diagnostic = diagnostic };
    self.snapshot.theme = try theme_parser.select(self.snapshot.theme);

    _ = lua_api.c.lua_getfield(state, -1, "client");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseClient(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "gui");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const parser: GuiConfigParser = .{ .state = state, .diagnostic = diagnostic };
        self.snapshot.gui = try parser.parse(self.snapshot.gui);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "runtime");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseRuntime(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "profiles");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        if (self.profile_len != 0) {
            diagnostic.set("profile '{s}' is not defined", .{self.profile_bytes[0..self.profile_len]});
            return error.UnknownProfile;
        }
        return;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.profiles must be a table", .{});
        return error.InvalidConfig;
    }
    try self.parseProfiles(-1, diagnostic);
}

fn parseProfile(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "theme", "client", "gui", "runtime", "plugins" }, .path = "profile" }, diagnostic);
    const theme_parser: ThemeParser = .{ .state = state, .diagnostic = diagnostic };
    self.snapshot.theme = try theme_parser.select(self.snapshot.theme);

    _ = lua_api.c.lua_getfield(state, absolute, "plugins");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try plugins_config.parse(state, &self.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "client");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseClient(-1, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "runtime");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseRuntime(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "gui");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const parser: GuiConfigParser = .{ .state = state, .diagnostic = diagnostic };
        self.snapshot.gui = try parser.parse(self.snapshot.gui);
    }
    lua_value.pop(state, 1);
}

fn parseProfiles(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    const base_snapshot = self.snapshot;
    var selected_snapshot: ?Snapshot = null;
    const selected_name = self.profile_bytes[0..self.profile_len];
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
        self.snapshot = base_snapshot;
        self.parseProfile(-1, diagnostic) catch |err| {
            lua_value.pop(state, 2);
            return err;
        };
        if (self.profile_len != 0 and std.mem.eql(u8, name, selected_name)) {
            selected_snapshot = self.snapshot;
        }
        lua_value.pop(state, 1);
    }
    self.snapshot = if (self.profile_len == 0)
        base_snapshot
    else
        selected_snapshot orelse {
            diagnostic.set("profile '{s}' is not defined", .{selected_name});
            return error.UnknownProfile;
        };
}

fn parseRuntime(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
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
        try commands_config.parseEngine(state, &self.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "session");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try session_config.parse(state, &self.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "agents");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try agents_config.parse(state, &self.snapshot.runtime, &self.unreported, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "history");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try history_config.parse(state, &self.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "proxy");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try proxy_config.parse(state, &self.snapshot.runtime, diagnostic);
    }
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "agent_descriptions");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try commands_config.parseAgentDescriptions(state, &self.snapshot.runtime, diagnostic);
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
    self.snapshot.runtime.graphics_pane_bytes = try lua_value.optionalMebibytes(state, .{
        .index = graphics,
        .name = "pane_mib",
        .default = self.snapshot.runtime.graphics_pane_bytes,
    }, diagnostic);
    self.snapshot.runtime.graphics_global_bytes = try lua_value.optionalMebibytes(state, .{
        .index = graphics,
        .name = "global_mib",
        .default = self.snapshot.runtime.graphics_global_bytes,
    }, diagnostic);
    const runtime = self.snapshot.runtime;
    if (runtime.graphics_pane_bytes < 2 * 1024 * 1024 or
        runtime.graphics_pane_bytes > core.max_image_bytes_per_pane or
        runtime.graphics_global_bytes < runtime.graphics_pane_bytes or
        runtime.graphics_global_bytes > core.max_image_bytes_global)
    {
        diagnostic.set("runtime graphics limits are outside Telar's safe bounds", .{});
        return error.InvalidConfig;
    }
}

fn parseClient(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client must be a table", .{});
        return error.InvalidConfig;
    }
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "prefix", "theme", "icons", "sidebar", "pane_gaps", "editor", "window_title", "sound", "notifications", "appearance", "input", "keybindings", "bars", "panels", "picks", "history" },
        .path = "config.client",
    }, diagnostic);

    _ = lua_api.c.lua_getfield(state, absolute, "prefix");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parsePrefix(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "history");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try client_history_config.parse(state, &self.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    // The terminal client chose Nerd Font or Unicode icons here; the window
    // draws its own, so the key is ignored and reported.
    _ = lua_api.c.lua_getfield(state, absolute, "icons");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        self.snapshot.retired.insert(.icons);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "sidebar");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseSidebar(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "pane_gaps");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.pane_gaps must be a boolean", .{});
            return error.InvalidConfig;
        }
        self.snapshot.pane_gaps = lua_api.c.lua_toboolean(state, -1) != 0;
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "editor");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const editor = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.editor must be a string", .{});
            return error.InvalidConfig;
        };
        if (editor.len == 0 or editor.len > data.config_values.max_editor_bytes or !std.unicode.utf8ValidateSlice(editor) or generation_support.hasControlBytes(editor)) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.editor must be a nonempty executable name or path of at most {d} bytes", .{data.config_values.max_editor_bytes});
            return error.InvalidConfig;
        }

        @memcpy(self.snapshot.editor_bytes[0..editor.len], editor);
        self.snapshot.editor_len = @intCast(editor.len);
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
        if (template.len > data.config_values.max_window_title_bytes or !std.unicode.utf8ValidateSlice(template) or generation_support.hasControlBytes(template)) {
            lua_value.pop(state, 1);
            diagnostic.set("config.client.window_title must be printable UTF-8 of at most {d} bytes", .{data.config_values.max_window_title_bytes});
            return error.InvalidConfig;
        }

        @memcpy(self.snapshot.window_title_bytes[0..template.len], template);
        self.snapshot.window_title_len = @intCast(template.len);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "sound");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseSound(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "notifications");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try notifications_config.parse(state, &self.snapshot, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "appearance");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        const parser: ThemeParser = .{ .state = state, .diagnostic = diagnostic };
        try parser.appearance(&self.snapshot);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "input");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseInputOptions(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    // Panels and picks come first: bindings and bars name them in
    // open_panel and pick.
    _ = lua_api.c.lua_getfield(state, absolute, "panels");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parsePanels(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "picks");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parsePicks(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "keybindings");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseBindings(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "bars");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseBars(-1, diagnostic);
    }
    lua_value.pop(state, 1);
}

fn parseBars(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bottom", "top", "sidebar_footer" }, .path = "config.client.bars" }, diagnostic);

    _ = lua_api.c.lua_getfield(state, absolute, "bottom");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseBottomBar(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "top");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseTopBar(-1, diagnostic);
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "sidebar_footer");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        try self.parseSidebarFooter(-1, diagnostic);
    }
    lua_value.pop(state, 1);
}

/// Reads `client.panels`, a table from panel names to `telar.panel` values.
/// Names are sorted so a panel keeps its index across equal reloads.
fn parsePanels(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.panels must be a table of telar.panel values", .{});
        return error.InvalidConfig;
    }

    var names: [data.bar_values.max_panels][]const u8 = undefined;
    const listed = try firstNames(state, absolute, &names, "config.client.panels keys must be panel names", diagnostic);
    if (listed.total > listed.kept) {
        self.dropped.insert(.panels);
        self.unreported.add(.{
            .limit = data.bar_values.panels_limit,
            .requested = listed.total,
        });
    }

    const count = listed.kept;
    for (names[0..count], 0..) |name, panel_index| {
        // Lua strings are NUL-terminated, and the key keeps this one alive.
        _ = lua_api.c.lua_getfield(state, absolute, @ptrCast(name.ptr));
        defer lua_value.pop(state, 1);
        self.snapshot.bars.panels[panel_index] = try self.parsePanel(.{ .index = -1, .name = name }, diagnostic);
    }

    self.snapshot.bars.panel_count = @intCast(count);
}

fn parsePanel(self: *Generation, input: PanelInput, diagnostic: *data.Diagnostic) !data.PanelDefinition {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, input.index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.panels.{s} must be a telar.panel value", .{input.name});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "panel_kind", "title", "mark", "icon", "width", "source", "refresh" },
        .path = "telar.panel",
    }, diagnostic);

    var definition: data.PanelDefinition = .{};
    definition.heading.setName(input.name) catch {
        diagnostic.set("panel name '{s}' must be 1..{d} letters, digits, '-' or '_'", .{ input.name, data.PanelHeading.max_name_bytes });
        return error.InvalidConfig;
    };
    const title = try lua_value.optionalStringField(state, .{ .index = absolute, .name = "title", .default = input.name }, diagnostic);
    definition.heading.setTitle(self.fitted(title, data.PanelHeading.title_limit)) catch {
        diagnostic.set("panel title must be printable text of at most {d} bytes", .{data.PanelHeading.max_title_bytes});
        return error.InvalidConfig;
    };

    _ = lua_api.c.lua_getfield(state, absolute, "mark");
    if (lua_value.string(state, -1)) |name| {
        definition.heading.mark = std.meta.stringToEnum(data.Mark, name) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("unknown panel mark '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "icon");
    if (lua_value.string(state, -1)) |name| {
        definition.heading.icon = bar_values.parseBarIcon(name) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("unknown panel icon '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    lua_value.pop(state, 1);

    const width = try lua_value.optionalIntegerField(state, .{ .index = absolute, .name = "width", .default = data.PanelHeading.default_width }, diagnostic);
    if (width < data.PanelHeading.min_width or width > data.PanelHeading.max_width) {
        diagnostic.set("panel width must be in {d}..{d}", .{ data.PanelHeading.min_width, data.PanelHeading.max_width });
        return error.InvalidConfig;
    }
    definition.heading.width = @intCast(width);

    _ = lua_api.c.lua_getfield(state, absolute, "source");
    const source = self.parseBarSource(-1, diagnostic) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };
    lua_value.pop(state, 1);
    definition.source = switch (source) {
        .dynamic => |value| .{ .dynamic = value },
        .command => |value| .{ .command = value },
        else => {
            diagnostic.set("panel '{s}' needs a render function or a command", .{input.name});
            return error.InvalidConfig;
        },
    };

    _ = lua_api.c.lua_getfield(state, absolute, "refresh");
    const refresh = lua_api.c.lua_toboolean(state, -1) != 0;
    lua_value.pop(state, 1);
    // Without every_ms a panel renders once per opening and on refresh_panel.
    if (!refresh) {
        switch (definition.source) {
            .dynamic => |*value| value.interval_ns = 0,
            .command => |*value| value.interval_ns = 0,
            else => unreachable,
        }
    }

    return definition;
}

/// Reads `client.picks`, a table from pick names to `telar.pick` values.
/// Names are sorted so a pick keeps its index across equal reloads.
fn parsePicks(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.picks must be a table of telar.pick values", .{});
        return error.InvalidConfig;
    }

    var names: [data.bar_values.max_picks][]const u8 = undefined;
    const listed = try firstNames(state, absolute, &names, "config.client.picks keys must be pick names", diagnostic);
    if (listed.total > listed.kept) {
        self.dropped.insert(.picks);
        self.unreported.add(.{
            .limit = data.bar_values.picks_limit,
            .requested = listed.total,
        });
    }

    const count = listed.kept;
    for (names[0..count], 0..) |name, pick_index| {
        // Lua strings are NUL-terminated, and the key keeps this one alive.
        _ = lua_api.c.lua_getfield(state, absolute, @ptrCast(name.ptr));
        defer lua_value.pop(state, 1);
        try self.parsePick(
            .{
                .index = -1,
                .name = name,
            },
            &self.snapshot.bars.picks[pick_index],
            diagnostic,
        );
    }

    self.snapshot.bars.pick_count = @intCast(count);
}

fn parsePick(self: *Generation, input: PanelInput, definition: *data.PickDefinition, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, input.index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.picks.{s} must be a telar.pick value", .{input.name});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "pick_kind", "title", "command", "items", "on_select", "timeout_ms", "refresh" },
        .path = "telar.pick",
    }, diagnostic);

    definition.* = .{};
    definition.heading.setName(input.name) catch {
        diagnostic.set("pick name '{s}' must be 1..{d} letters, digits, '-' or '_'", .{ input.name, data.PanelHeading.max_name_bytes });
        return error.InvalidConfig;
    };

    const title = try lua_value.optionalStringField(
        state,
        .{
            .index = absolute,
            .name = "title",
            .default = input.name,
        },
        diagnostic,
    );
    definition.heading.setTitle(self.fitted(title, data.PanelHeading.title_limit)) catch {
        diagnostic.set("pick title must be printable text of at most {d} bytes", .{data.PanelHeading.max_title_bytes});
        return error.InvalidConfig;
    };

    const timeout_ms = try parseCommandTimeout(state, absolute, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "command");

    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        var list: data.BarCommand = .{
            .generation = self.number,
            .interval_ns = 0,
            .timeout_ms = timeout_ms,
        };

        parseCommandArguments(state, -1, &list, diagnostic) catch |err| {
            lua_value.pop(state, 1);
            return err;
        };

        definition.list = list;
    }

    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "items");
    definition.items = self.parsePickItems(
        .{
            .index = -1,
            .name = input.name,
        },
        definition.list != null,
        diagnostic,
    ) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };

    lua_value.pop(state, 1);

    if (definition.list == null and definition.items == null) {
        diagnostic.set("pick '{s}' needs items or a command", .{input.name});
        return error.InvalidConfig;
    }

    definition.on_select = .{
        .generation = self.number,
        .interval_ns = 0,
        .timeout_ms = timeout_ms,
    };

    _ = lua_api.c.lua_getfield(state, absolute, "on_select");
    parseCommandArguments(state, -1, &definition.on_select, diagnostic) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };

    lua_value.pop(state, 1);

    if (!definition.receivesChoice()) {
        diagnostic.set("pick '{s}' on_select needs an argument \"{s}\" after the program for the chosen value", .{ input.name, data.PickDefinition.choice_marker });
        return error.InvalidConfig;
    }

    _ = lua_api.c.lua_getfield(state, absolute, "refresh");
    defer lua_value.pop(state, 1);
    switch (lua_api.c.lua_type(state, -1)) {
        lua_api.c.LUA_TNIL => {},
        lua_api.c.LUA_TBOOLEAN => definition.refresh = lua_api.c.lua_toboolean(state, -1) != 0,
        else => {
            diagnostic.set("pick '{s}' refresh must be a boolean", .{input.name});
            return error.InvalidConfig;
        },
    }
}

// A pick's `items`: a list checked now, or with a command a function that
// parses its output. A list is parsed once here so a mistake fails the load
// instead of the first click.
fn parsePickItems(self: *Generation, input: PanelInput, listed: bool, diagnostic: *data.Diagnostic) !?data.CallbackRef {
    const state = self.vm.state;
    switch (lua_api.c.lua_type(state, input.index)) {
        lua_api.c.LUA_TNIL => return null,
        lua_api.c.LUA_TFUNCTION => {
            if (!listed) {
                diagnostic.set("pick '{s}' items can be a function only with a command, whose output it reads", .{input.name});
                return error.InvalidConfig;
            }

            return try self.referenceBarValue(input.index, diagnostic);
        },
        lua_api.c.LUA_TTABLE => {
            if (listed) {
                diagnostic.set("pick '{s}' items must be a function when it has a command", .{input.name});
                return error.InvalidConfig;
            }

            const items = try self.gpa.create(data.PickItems);
            defer self.gpa.destroy(items);
            items.clear();
            pick_values.parse(state, input.index, items, diagnostic) catch return error.InvalidConfig;
            var buffer: [data.PickItems.max_reaches]core.LimitReach = undefined;
            for (items.reaches(&buffer)) |reach| {
                self.unreported.add(reach);
            }

            return try self.referenceBarValue(input.index, diagnostic);
        },
        else => {
            diagnostic.set("pick '{s}' items must be a list or a function", .{input.name});
            return error.InvalidConfig;
        },
    }
}

/// Keeps the `names.len` first keys, in name order, of the table at
/// `absolute`, so a table past its limit keeps the same entries whatever
/// order Lua walks it in. The key strings stay alive in the table.
fn firstNames(state: *lua_api.c.lua_State, absolute: c_int, names: [][]const u8, invalid_key: []const u8, diagnostic: *data.Diagnostic) !ListedNames {
    var listed: ListedNames = .{};
    lua_api.c.lua_pushnil(state);
    while (lua_api.c.lua_next(state, absolute) != 0) {
        lua_value.pop(state, 1);
        const name = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("{s}", .{invalid_key});
            return error.InvalidConfig;
        };

        listed.total += 1;
        if (listed.kept == names.len and !lessName({}, name, names[listed.kept - 1])) {
            continue;
        }

        var slot = @min(listed.kept, names.len - 1);
        while (slot > 0 and lessName({}, name, names[slot - 1])) : (slot -= 1) {
            names[slot] = names[slot - 1];
        }

        names[slot] = name;
        listed.kept = @min(listed.kept + 1, names.len);
    }

    return listed;
}

/// The start of `text` that fits `limit`, cut at a character; a cut leaves
/// the limit for the client to report.
fn fitted(self: *Generation, text: []const u8, limit: core.Limit) []const u8 {
    if (text.len <= limit.value) {
        return text;
    }

    self.unreported.add(.{
        .limit = limit,
        .requested = text.len,
    });
    return data.bar_text.prefix(text, @intCast(limit.value));
}

/// The index an action gets when it names a panel or pick that may have
/// been left out at its limit: no configuration entry has it, so running
/// the action does nothing. Null when nothing was left out, so the name is
/// simply unknown.
fn droppedIndex(self: *const Generation, entries: DroppedEntries) ?u8 {
    if (!self.dropped.contains(entries)) {
        return null;
    }

    return data.BarConfiguration.dropped_index;
}

const DroppedEntries = enum {
    panels,
    picks,
};

/// How many keys a table has and how many `firstNames` kept.
const ListedNames = struct {
    kept: usize = 0,
    total: usize = 0,
};

fn lessName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn parseSidebarFooter(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars.sidebar_footer must be a list of telar.bar values", .{});
        return error.InvalidConfig;
    }

    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > self.snapshot.bars.sidebar_footer.len) {
        diagnostic.set("config.client.bars.sidebar_footer accepts at most {d} slots", .{self.snapshot.bars.sidebar_footer.len});
        return error.InvalidConfig;
    }
    try lua_value.ensureArrayOnly(state, .{ .index = absolute, .count = count, .path = "config.client.bars.sidebar_footer" }, diagnostic);

    var parsed: [3]data.bar_values.Source = .{ .empty, .empty, .empty };
    for (0..count) |slot_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(slot_index + 1));
        defer lua_value.pop(state, 1);
        const source = try self.parseBarSource(-1, diagnostic);
        if (source == .tabs) {
            diagnostic.set("config.client.bars.sidebar_footer cannot contain tabs", .{});
            return error.InvalidConfig;
        }

        parsed[slot_index] = source;
    }

    self.snapshot.bars.sidebar_footer = parsed;
}

fn parseBottomBar(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars.bottom must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "left", "center", "right" }, .path = "config.client.bars.bottom" }, diagnostic);
    var parsed: [3]data.bar_values.Source = .{ .empty, .empty, .empty };
    inline for (.{ "left", "center", "right" }, 0..) |field, source_index| {
        _ = lua_api.c.lua_getfield(state, absolute, field);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            parsed[source_index] = try self.parseBarSource(-1, diagnostic);
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

    self.snapshot.bars.bottom = parsed;
}

fn parseTopBar(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.bars.top must be a table", .{});
        return error.InvalidConfig;
    }

    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"right"}, .path = "config.client.bars.top" }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "right");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        self.snapshot.bars.top_right = .empty;
        return;
    }

    const source = try self.parseBarSource(-1, diagnostic);
    if (source == .tabs) {
        diagnostic.set("config.client.bars.top.right cannot contain tabs", .{});
        return error.InvalidConfig;
    }

    self.snapshot.bars.top_right = source;
}

fn parseBarSource(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.bar_values.Source {
    const state = self.vm.state;
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
    if (std.mem.eql(u8, kind, "machines")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"bar_kind"}, .path = "bar machines" }, diagnostic);
        return .machines;
    }
    if (std.mem.eql(u8, kind, "static")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "value" }, .path = "bar static block" }, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "value");
        defer lua_value.pop(state, 1);
        var content: data.Content = .{};
        try component_values.parse(self, &content, .{
            .index = -1,
            .surface = .bar,
        }, diagnostic);
        return .{ .static = content };
    }
    if (std.mem.eql(u8, kind, "dynamic")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "bar_kind", "every_ms", "render" }, .path = "bar dynamic block" }, diagnostic);
        const interval_ns = try bar_values.parseBarInterval(state, absolute, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "render");
        defer lua_value.pop(state, 1);
        const callback = try self.registerBarCallback(-1, diagnostic);
        return .{ .dynamic = .{ .callback = callback, .interval_ns = interval_ns } };
    }
    if (std.mem.eql(u8, kind, "command")) {
        return self.parseBarCommand(absolute, diagnostic);
    }

    diagnostic.set("unknown bar value '{s}'", .{kind});
    return error.InvalidConfig;
}

fn parseBarCommand(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.bar_values.Source {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "bar_kind", "command", "every_ms", "timeout_ms", "render" },
        .path = "bar command block",
    }, diagnostic);

    const interval_ns = try bar_values.parseBarInterval(state, absolute, diagnostic);
    var command: data.BarCommand = .{
        .generation = self.number,
        .interval_ns = interval_ns,
        .timeout_ms = try parseCommandTimeout(state, absolute, diagnostic),
    };
    _ = lua_api.c.lua_getfield(state, absolute, "command");
    parseCommandArguments(state, -1, &command, diagnostic) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "render");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        command.render = try self.registerBarCallback(-1, diagnostic);
    }

    return .{ .command = command };
}

/// The `timeout_ms` of a table that runs a command, 2 seconds when absent.
fn parseCommandTimeout(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !u32 {
    _ = lua_api.c.lua_getfield(state, index, "timeout_ms");
    const timeout_value = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        default_command_timeout_ms
    else
        lua_value.integer(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("bar command timeout_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    lua_value.pop(state, 1);
    if (timeout_value < data.bar_values.min_command_timeout_ms or timeout_value > data.bar_values.max_command_timeout_ms) {
        diagnostic.set(
            "bar command timeout_ms must be in {d}..{d}",
            .{ data.bar_values.min_command_timeout_ms, data.bar_values.max_command_timeout_ms },
        );
        return error.InvalidConfig;
    }

    return @intCast(timeout_value);
}

/// Appends the argv array at `index` to `command`.
fn parseCommandArguments(state: *lua_api.c.lua_State, index: c_int, command: *data.BarCommand, diagnostic: *data.Diagnostic) !void {
    if (lua_api.c.lua_type(state, index) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("bar command must be an array", .{});
        return error.InvalidConfig;
    }

    const command_table = lua_api.c.lua_absindex(state, index);
    const count = lua_api.c.lua_rawlen(state, command_table);
    if (count == 0 or count > data.bar_values.max_command_args) {
        diagnostic.set("bar command must contain 1..{d} arguments", .{data.bar_values.max_command_args});
        return error.InvalidConfig;
    }

    try lua_value.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "bar command" }, diagnostic);
    for (0..count) |argument_index| {
        _ = lua_api.c.lua_geti(state, command_table, @intCast(argument_index + 1));
        defer lua_value.pop(state, 1);
        const argument_value = lua_value.string(state, -1) orelse {
            diagnostic.set("bar command argument {d} must be a string", .{argument_index + 1});
            return error.InvalidConfig;
        };
        command.appendArgument(argument_value) catch |err| {
            diagnostic.set("invalid bar command: {s}", .{@errorName(err)});
            return error.InvalidConfig;
        };
    }
}

fn registerBarCallback(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.CallbackRef {
    const state = self.vm.state;
    if (lua_api.c.lua_type(state, index) != lua_api.c.LUA_TFUNCTION) {
        diagnostic.set("bar render must be a Lua function", .{});
        return error.InvalidConfig;
    }

    return self.referenceBarValue(index, diagnostic);
}

/// Keeps the Lua value at `index` for later bar or pick invocations.
fn referenceBarValue(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !data.CallbackRef {
    const state = self.vm.state;
    if (self.bar_callback_count == data.config_values.max_bar_callbacks) {
        diagnostic.set("configuration exceeds {d} bar callbacks", .{data.config_values.max_bar_callbacks});
        return error.InvalidConfig;
    }

    lua_api.c.lua_pushvalue(state, index);
    const registry_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    const id = self.bar_callback_count;
    self.bar_callbacks[id] = .{ .registry_ref = registry_ref };
    self.bar_callback_count += 1;
    return .{ .generation = self.number, .id = id };
}

fn parsePrefix(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const value = lua_value.string(self.vm.state, index) orelse {
        diagnostic.set("config.client.prefix must be a string", .{});
        return error.InvalidConfig;
    };
    const prefix = keyinput.chord.parseKey(value) catch |err| {
        diagnostic.set("invalid config.client.prefix: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };
    self.snapshot.prefix = prefix;
    for (self.snapshot.bindings[0..self.snapshot.binding_count], 0..) |*binding, binding_index| {
        if (self.snapshot.bindings_prefixed[binding_index]) {
            binding.keys[0] = prefix;
        }
    }
}

fn parseInputOptions(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.input must be a table", .{});
        return error.InvalidConfig;
    }
    // The terminal client waited this long for the rest of an escape
    // sequence; the window receives whole keys, so the key is ignored and
    // reported.
    _ = lua_api.c.lua_getfield(state, absolute, "escape_timeout_ms");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        self.snapshot.retired.insert(.escape_timeout);
    }
    lua_value.pop(state, 1);

    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "escape_timeout_ms", "sequence_timeout_ms" },
        .path = "config.client.input",
    }, diagnostic);
    self.snapshot.input_sequence_timeout_ns = try lua_value.optionalMilliseconds(state, .{
        .index = absolute,
        .name = "sequence_timeout_ms",
        .default_ns = self.snapshot.input_sequence_timeout_ns,
        .minimum_ms = 10,
        .maximum_ms = 10_000,
    }, diagnostic);
}

fn parseSound(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
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
            @field(self.snapshot.sound, field) = lua_api.c.lua_toboolean(state, -1) != 0;
        }
        lua_value.pop(state, 1);
    }
}

fn parseSidebar(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
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
        self.snapshot.sidebar_visible = lua_api.c.lua_toboolean(state, -1) != 0;
    }
    lua_value.pop(state, 1);

    // The terminal client chose how to draw its sidebar here; the window
    // draws its own, so the key is ignored and reported.
    _ = lua_api.c.lua_getfield(state, absolute, "renderer");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        self.snapshot.retired.insert(.sidebar_renderer);
    }
    lua_value.pop(state, 1);
}

fn parseBindings(self: *Generation, index: c_int, diagnostic: *data.Diagnostic) !void {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.keybindings must be an array", .{});
        return error.InvalidConfig;
    }
    const listed = lua_api.c.lua_rawlen(state, absolute);
    const count = @min(listed, data.config_values.max_bindings);
    if (listed > count) {
        self.unreported.add(.{
            .limit = data.config_values.bindings_limit,
            .requested = listed,
        });
    }

    // A binding whose action stopped at a limit is left out; the limit is
    // already kept for the client to report.
    var kept: u16 = 0;
    for (0..count) |binding_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(binding_index + 1));
        defer lua_value.pop(state, 1);
        const parsed = self.parseBinding(.{ .index = -1, .position = binding_index }, diagnostic) catch |err| switch (err) {
            error.TooManyArguments, error.ArgumentsTooLarge, error.TooManyCommandTabs => continue,
            else => return err,
        };

        self.snapshot.bindings[kept] = parsed.binding;
        self.snapshot.bindings_prefixed[kept] = parsed.prefixed;
        kept += 1;
    }

    self.snapshot.binding_count = kept;
}

fn parseBinding(self: *Generation, binding_input: BindingInput, diagnostic: *data.Diagnostic) !ParsedBinding {
    const state = self.vm.state;
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
    const key_limit: usize = if (prefixed) generation_support.max_binding_suffix_keys else data.config_values.max_binding_keys;
    if (key_count == 0 or key_count > key_limit) {
        lua_value.pop(state, 1);
        diagnostic.set(
            "keybinding {d}.keys must contain 1..{d} keys",
            .{ binding_input.position + 1, key_limit },
        );
        return error.InvalidConfig;
    }
    var keys: [data.config_values.max_binding_keys]keyinput.Key = undefined;
    const key_offset: usize = @intFromBool(prefixed);
    if (prefixed) {
        keys[0] = self.snapshot.prefix;
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
        keys[key_offset + key_index] = keyinput.chord.parseKey(name) catch |err| {
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
    const action = self.parseAction(.{ .index = -1, .expression = expression }, diagnostic) catch |err| {
        lua_value.pop(state, 1);
        return err;
    };
    lua_value.pop(state, 1);
    const total_key_count = key_offset + key_count;
    const binding = data.config_values.ConfiguredBinding.init(keys[0..total_key_count], action) catch |err| {
        diagnostic.set("invalid keybinding {d}: {s}", .{ binding_input.position + 1, @errorName(err) });
        return error.InvalidConfig;
    };
    switch (binding.action) {
        .lua_callback, .lua_expr => |reference| {
            const callback = &self.callbacks[reference.id];
            @memcpy(callback.trigger[0..binding.len], binding.keys[0..binding.len]);
            callback.trigger_len = binding.len;
        },
        else => {},
    }
    return .{ .binding = binding, .prefixed = prefixed };
}

fn syncCallbackTriggers(self: *Generation) void {
    for (self.snapshot.bindings[0..self.snapshot.binding_count]) |*binding| switch (binding.action) {
        .lua_callback, .lua_expr => |reference| {
            const callback = &self.callbacks[reference.id];
            @memcpy(callback.trigger[0..binding.len], binding.keys[0..binding.len]);
            callback.trigger_len = binding.len;
        },
        else => {},
    };
}

fn parseAction(self: *Generation, action_input: ActionInput, diagnostic: *data.Diagnostic) !data.Action {
    const state = self.vm.state;
    const absolute = lua_api.c.lua_absindex(state, action_input.index);
    if (lua_api.c.lua_type(state, absolute) == lua_api.c.LUA_TFUNCTION) {
        if (self.callback_count == data.config_values.max_bindings) {
            diagnostic.set("configuration exceeds {d} Lua callbacks", .{data.config_values.max_bindings});
            return error.InvalidConfig;
        }
        lua_api.c.lua_pushvalue(state, absolute);
        const registry_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
        const id = self.callback_count;
        self.callbacks[id] = .{
            .registry_ref = registry_ref,
            .expression = action_input.expression,
        };
        self.callback_count += 1;
        const reference: data.InputCallbackRef = .{
            .generation = self.number,
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
        return data.Action.parse(name) catch {
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
        const parsed_direction: data.ScrollDirection = if (std.mem.eql(u8, direction, "up"))
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
        const parsed_direction: data.InputDirection = if (std.mem.eql(u8, direction, "left"))
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
        if (count == 0) {
            diagnostic.set("command-tab command must contain 1..{d} arguments", .{data.CommandTab.max_arguments});
            return error.InvalidConfig;
        }

        if (count > data.CommandTab.max_arguments) {
            diagnostic.set("command-tab command has {d} arguments; at most {d} fit", .{ count, data.CommandTab.max_arguments });
            self.unreported.add(.{
                .limit = data.CommandTab.arguments_limit,
                .requested = count,
            });
            return error.TooManyArguments;
        }

        try lua_value.ensureArrayOnly(state, .{ .index = command_table, .count = count, .path = "command-tab command" }, diagnostic);
        var argument_storage: [data.CommandTab.max_arguments][]const u8 = undefined;
        var argv_bytes: usize = 0;
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
            argv_bytes += text.len;
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
        const command = data.CommandTab.init(argument_storage[0..count], label) catch |err| switch (err) {
            error.ArgumentsTooLarge => {
                diagnostic.set("command-tab command has {d} bytes; at most {d} fit", .{ argv_bytes, data.CommandTab.max_command_bytes });
                self.unreported.add(.{
                    .limit = data.CommandTab.command_bytes_limit,
                    .requested = argv_bytes,
                });
                return err;
            },
            else => {
                diagnostic.set("command-tab command or label is invalid or too long", .{});
                return error.InvalidConfig;
            },
        };
        const id = self.snapshot.command_tabs.add(&command) catch |err| {
            diagnostic.set("configuration opens more than {d} different command tabs", .{CommandTabs.capacity});
            self.unreported.add(.{
                .limit = CommandTabs.limit,
            });
            return err;
        };
        return .{ .command_tab = .{
            .generation = self.number,
            .id = id,
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
        const level: core.NotificationLevel = if (std.mem.eql(u8, level_name, "info"))
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
            .default = core.default_notification_duration_ms,
        }, diagnostic);
        if (duration < core.min_notification_duration_ms or
            duration > core.max_notification_duration_ms)
        {
            diagnostic.set(
                "notification duration_ms must be in {d}..{d}",
                .{
                    core.min_notification_duration_ms,
                    core.max_notification_duration_ms,
                },
            );
            return error.InvalidConfig;
        }

        var target: core.NotificationTarget = .none;
        var target_count: u8 = 0;
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "pane_id" }, diagnostic)) |raw| {
            target = .{ .pane = core.pane(raw) catch {
                diagnostic.set("notification pane_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "tab_id" }, diagnostic)) |raw| {
            target = .{ .tab = core.tab(raw) catch {
                diagnostic.set("notification tab_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (try lua_value.optionalPositiveId(state, .{ .index = absolute, .name = "workspace_id" }, diagnostic)) |raw| {
            target = .{ .workspace = core.workspace(raw) catch {
                diagnostic.set("notification workspace_id is invalid", .{});
                return error.InvalidConfig;
            } };
            target_count += 1;
        }
        if (target_count > 1) {
            diagnostic.set("notification accepts only one click target", .{});
            return error.InvalidConfig;
        }
        return .{ .notification = data.Notification.init(.{
            .level = level,
            .duration_ms = @intCast(duration),
            .target = target,
            .title = self.fitted(title, data.Notification.title_limit),
            .message = self.fitted(body, data.Notification.message_limit),
        }) catch {
            diagnostic.set("notification title or body is invalid or too long", .{});
            return error.InvalidConfig;
        } };
    }
    if (std.mem.eql(u8, kind, "open-panel")) {
        try lua_value.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "panel" },
            .path = "action",
        }, diagnostic);
        const name = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "panel" }, diagnostic);
        const index = self.snapshot.bars.panelIndex(name) orelse self.droppedIndex(.panels) orelse {
            diagnostic.set("open_panel names an unknown panel '{s}'", .{name});
            return error.InvalidConfig;
        };
        return .{ .open_panel = index };
    }
    if (std.mem.eql(u8, kind, "pick")) {
        try lua_value.ensureOnlyFields(state, .{
            .index = absolute,
            .allowed = &.{ "kind", "pick" },
            .path = "action",
        }, diagnostic);
        const name = try lua_value.requiredStringField(
            state,
            .{
                .index = absolute,
                .name = "pick",
            },
            diagnostic,
        );
        const index = self.snapshot.bars.pickIndex(name) orelse self.droppedIndex(.picks) orelse {
            diagnostic.set("pick names an unknown pick '{s}'", .{name});
            return error.InvalidConfig;
        };
        return .{ .pick = index };
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
            .plugin = core.stableId(plugin_name),
            .action = core.stableId(action_name),
        } };
    }
    const action = data.Action.parse(kind) catch {
        diagnostic.set("unknown action kind '{s}'", .{kind});
        return error.InvalidConfig;
    };
    try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"kind"}, .path = "action" }, diagnostic);
    return action;
}

const default_command_timeout_ms = 2_000;

const BarCallback = struct {
    registry_ref: c_int,
};

const BarInvocation = struct {
    reference: data.CallbackRef,
    context: BarCallbackContext,
    surface: component_values.Surface = .bar,
};

const PanelInput = struct {
    index: c_int,
    name: []const u8,
};

const SourceInput = struct {
    source: []const u8,
    source_name: [*:0]const u8,
    config_dir: []const u8 = ".",
    number: u64,
    profile: ?[]const u8 = null,
};

const CallbackPreparation = struct {
    invocation: CallbackInvocation,
    expression: bool,
};

const CallbackInvocation = struct {
    reference: data.InputCallbackRef,
    context: data.CallbackContext,
};

const LoadContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    diagnostic: *data.Diagnostic,
};

const BindingInput = struct {
    index: c_int,
    position: usize,
};

const ParsedBinding = struct {
    binding: data.config_values.ConfiguredBinding,
    prefixed: bool,
};

const ActionInput = struct {
    index: c_int,
    expression: bool,
};

const FileInput = struct {
    path: []const u8,
    number: u64,
    profile: ?[]const u8 = null,
};
