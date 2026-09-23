const backend = @import("telar-backend");
const client_module = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const RunOptions = @import("arguments/RunOptions.zig");
const ClientPreparation = @import("ClientPreparation.zig");
const config = @import("config.zig");
const LaunchDefaults = @import("LaunchDefaults.zig");
const plugin = @import("plugin.zig");
const client = @import("client.zig");
const Launch = @This();

process: std.process.Init,
options: *const RunOptions,
endpoint: []const u8,
argument_storage: [backend.max_args][]const u8 = undefined,
argument_count: usize = 0,
cwd_buffer: [std.fs.max_path_bytes]u8 = undefined,
cwd_len: usize = 0,
config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
generation: ?*client_module.Generation = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
plugin_registry: ?*client_module.Registry = null,
trust_store: ?*core.TrustStore = null,
trust_path: ?[]const u8 = null,
owns_resources: bool = true,

pub fn prepare(self: *Launch, preparation: ClientPreparation) !void {
    self.* = .{
        .process = preparation.process,
        .options = preparation.options,
        .endpoint = preparation.endpoint,
    };
    errdefer self.deinit();

    try self.prepareChild(preparation.remote_defaults);
    self.generation = try config.loadGeneration(preparation.process, .{
        .path = preparation.options.config,
        .disabled = preparation.options.no_config,
        .profile = preparation.options.profile,
    }, &self.config_path_buffer);
    self.config_path = if (self.generation != null)
        if (preparation.options.config) |value|
            std.mem.span(value)
        else
            try client_module.defaultPath(preparation.process.minimal.environ, &self.config_path_buffer)
    else
        null;
    self.config_mtime_ns = if (self.config_path) |path|
        self.generation.?.watchFingerprint(preparation.process.io, path)
    else
        0;

    if (self.generation) |generation| {
        try self.preparePlugins(generation);
    }
}

pub fn prepareChild(self: *Launch, defaults: ?LaunchDefaults) !void {
    if (defaults) |remote_launch| {
        if (remote_launch.cwd.len > self.cwd_buffer.len) {
            return error.NameTooLong;
        }

        @memcpy(self.cwd_buffer[0..remote_launch.cwd.len], remote_launch.cwd);
        self.cwd_len = remote_launch.cwd.len;
        if (!self.options.command_set) {
            self.argument_storage[0] = remote_launch.shell;
            self.argument_count = 1;
            return;
        }
    } else {
        self.cwd_len = try std.Io.Dir.cwd().realPathFile(self.process.io, ".", &self.cwd_buffer);
    }

    while (self.options.command.argv[self.argument_count]) |argument| : (self.argument_count += 1) {
        self.argument_storage[self.argument_count] = std.mem.span(argument);
    }
}

fn preparePlugins(self: *Launch, generation: *client_module.Generation) !void {
    const resolved_trust_path = try plugin.trustPath(self.process.minimal.environ, &self.trust_path_buffer);
    const loaded_trust = try plugin.loadTrustStore(self.process, resolved_trust_path);
    self.trust_store = try self.process.gpa.create(core.TrustStore);
    self.trust_store.?.* = loaded_trust;

    const registry_value = try client_module.Registry.loadWithTrust(
        .{
            .gpa = self.process.gpa,
            .io = self.process.io,
            .config_dir = generation.configDir(),
        },
        generation.pluginSlice(),
        self.trust_store.?,
    );
    try registry_value.validateConfiguredActions(generation.snapshot.bindingSlice());
    self.plugin_registry = try self.process.gpa.create(client_module.Registry);
    self.plugin_registry.?.* = registry_value;
    self.config_mtime_ns ^= @as(i128, self.plugin_registry.?.watchFingerprint(self.process.gpa, self.process.io));
    self.config_mtime_ns ^= @as(i128, client_module.config_reload.trustWatchFingerprint(self.process.io, resolved_trust_path));
    self.trust_path = resolved_trust_path;
}

pub fn frontendOptions(self: *const Launch) client_module.Options {
    const snapshot = if (self.generation) |generation| &generation.snapshot else null;
    const options = self.options;
    return .{
        .arguments = self.argument_storage[0..self.argument_count],
        .cwd = self.cwd_buffer[0..self.cwd_len],
        .endpoint = self.endpoint,
        .prefix = if (snapshot) |value| value.prefix else data.keybind.default_prefix,
        .bindings = if (snapshot) |value| value.bindingSlice() else &.{},
        .gui = if (snapshot) |value| value.gui else .{},
        .theme = if (options.theme_set)
            options.theme
        else if (snapshot) |value|
            value.theme
        else
            options.theme,
        .icon_theme = if (snapshot) |value| value.icon_theme else .unicode,
        .sidebar_rendering = if (options.sidebar_renderer_set)
            options.sidebar_rendering
        else if (snapshot) |value|
            value.sidebar_rendering
        else
            options.sidebar_rendering,
        .sidebar_visible = if (snapshot) |value| value.sidebar_visible else true,
        .pane_gaps = if (snapshot) |value| value.pane_gaps else true,
        .sound = if (snapshot) |value| value.sound else .{},
        .bars = if (snapshot) |value| value.bars.presentation() else .{},
        .host_shared_memory = self.options.remote == null and
            client.supportsHostSharedMemory(self.process.minimal.environ),
        .input_escape_timeout_ns = if (snapshot) |value|
            value.input_escape_timeout_ns
        else
            data.keybind.default_escape_timeout_ns,
        .input_sequence_timeout_ns = if (snapshot) |value|
            value.input_sequence_timeout_ns
        else
            data.keybind.default_sequence_timeout_ns,
        .lua_generation = self.generation,
        .config_path = self.config_path,
        .config_mtime_ns = self.config_mtime_ns,
        .theme_locked = options.theme_set,
        .sidebar_renderer_locked = options.sidebar_renderer_set,
        .plugin_registry = self.plugin_registry,
        .trust_store = self.trust_store,
        .trust_path = self.trust_path,
        .profile = if (options.profile) |value| std.mem.span(value) else null,
        .editor = client.configuredEditor(self.process.minimal.environ),
        .environ = self.process.minimal.environ,
    };
}

pub fn transferResources(self: *Launch) void {
    self.owns_resources = false;
}

pub fn deinit(self: *Launch) void {
    if (!self.owns_resources) {
        return;
    }

    if (self.plugin_registry) |registry| {
        self.process.gpa.destroy(registry);
    }
    if (self.trust_store) |store| {
        self.process.gpa.destroy(store);
    }
    if (self.generation) |generation| {
        generation.deinit();
    }
    self.owns_resources = false;
}
