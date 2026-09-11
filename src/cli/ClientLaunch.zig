const std = @import("std");
const RunOptionsType = @import("arguments/RunOptions.zig");
const max_args_module = @import("telar-backend").max_args;
const GenerationType = @import("telar-frontend").Generation;
const RegistryType = @import("telar-frontend").Registry;
const TrustStoreType = @import("telar-core").TrustStore;
const ClientPreparation = @import("ClientPreparation.zig");
const config = @import("config.zig");
const defaultPath_module = @import("telar-frontend").defaultPath;
const LaunchDefaultsType = @import("LaunchDefaults.zig");
const plugin = @import("plugin.zig");
const trustWatchFingerprint_module = @import("telar-frontend").trustWatchFingerprint;
const OptionsType = @import("telar-frontend").Options;
const default_prefix_module = @import("telar-client").default_prefix;
const client = @import("client.zig");
const default_escape_timeout_ns_module = @import("telar-client").default_escape_timeout_ns;
const default_sequence_timeout_ns_module = @import("telar-client").default_sequence_timeout_ns;
const Launch = @This();

process: std.process.Init,
options: *const RunOptionsType,
endpoint: []const u8,
argument_storage: [max_args_module][]const u8 = undefined,
argument_count: usize = 0,
cwd_buffer: [std.fs.max_path_bytes]u8 = undefined,
cwd_len: usize = 0,
config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
generation: ?*GenerationType = null,
config_path: ?[]const u8 = null,
config_mtime_ns: i128 = 0,
plugin_registry: ?*RegistryType = null,
trust_store: ?*TrustStoreType = null,
trust_path: ?[]const u8 = null,
owns_resources: bool = true,

pub fn prepare(launch: *Launch, preparation: ClientPreparation) !void {
    launch.* = .{
        .process = preparation.process,
        .options = preparation.options,
        .endpoint = preparation.endpoint,
    };
    errdefer launch.deinit();

    try launch.prepareChild(preparation.remote_defaults);
    launch.generation = try config.loadGeneration(preparation.process, .{
        .path = preparation.options.config,
        .disabled = preparation.options.no_config,
        .profile = preparation.options.profile,
    }, &launch.config_path_buffer);
    launch.config_path = if (launch.generation != null)
        if (preparation.options.config) |value|
            std.mem.span(value)
        else
            try defaultPath_module(preparation.process.minimal.environ, &launch.config_path_buffer)
    else
        null;
    launch.config_mtime_ns = if (launch.config_path) |path|
        launch.generation.?.watchFingerprint(preparation.process.io, path)
    else
        0;

    if (launch.generation) |generation| {
        try launch.preparePlugins(generation);
    }
}

pub fn prepareChild(launch: *Launch, defaults: ?LaunchDefaultsType) !void {
    if (defaults) |remote_launch| {
        if (remote_launch.cwd.len > launch.cwd_buffer.len) {
            return error.NameTooLong;
        }

        @memcpy(launch.cwd_buffer[0..remote_launch.cwd.len], remote_launch.cwd);
        launch.cwd_len = remote_launch.cwd.len;
        if (!launch.options.command_set) {
            launch.argument_storage[0] = remote_launch.shell;
            launch.argument_count = 1;
            return;
        }
    } else {
        launch.cwd_len = try std.Io.Dir.cwd().realPathFile(launch.process.io, ".", &launch.cwd_buffer);
    }

    while (launch.options.command.argv[launch.argument_count]) |argument| : (launch.argument_count += 1) {
        launch.argument_storage[launch.argument_count] = std.mem.span(argument);
    }
}

fn preparePlugins(launch: *Launch, generation: *GenerationType) !void {
    const resolved_trust_path = try plugin.trustPath(launch.process.minimal.environ, &launch.trust_path_buffer);
    const loaded_trust = try plugin.loadTrustStore(launch.process, resolved_trust_path);
    launch.trust_store = try launch.process.gpa.create(TrustStoreType);
    launch.trust_store.?.* = loaded_trust;

    const registry_value = try RegistryType.loadWithTrust(
        .{
            .gpa = launch.process.gpa,
            .io = launch.process.io,
            .config_dir = generation.configDir(),
        },
        generation.pluginSlice(),
        launch.trust_store.?,
    );
    try registry_value.validateConfiguredActions(generation.snapshot.bindingSlice());
    launch.plugin_registry = try launch.process.gpa.create(RegistryType);
    launch.plugin_registry.?.* = registry_value;
    launch.config_mtime_ns ^= @as(i128, launch.plugin_registry.?.watchFingerprint(launch.process.gpa, launch.process.io));
    launch.config_mtime_ns ^= @as(i128, trustWatchFingerprint_module(launch.process.io, resolved_trust_path));
    launch.trust_path = resolved_trust_path;
}

pub fn frontendOptions(launch: *const Launch) OptionsType {
    const snapshot = if (launch.generation) |generation| &generation.snapshot else null;
    const options = launch.options;
    return .{
        .arguments = launch.argument_storage[0..launch.argument_count],
        .cwd = launch.cwd_buffer[0..launch.cwd_len],
        .endpoint = launch.endpoint,
        .prefix = if (snapshot) |value| value.prefix else default_prefix_module,
        .bindings = if (snapshot) |value| value.bindingSlice() else &.{},
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
        .host_shared_memory = launch.options.remote == null and
            client.supportsHostSharedMemory(launch.process.minimal.environ),
        .input_escape_timeout_ns = if (snapshot) |value|
            value.input_escape_timeout_ns
        else
            default_escape_timeout_ns_module,
        .input_sequence_timeout_ns = if (snapshot) |value|
            value.input_sequence_timeout_ns
        else
            default_sequence_timeout_ns_module,
        .lua_generation = launch.generation,
        .config_path = launch.config_path,
        .config_mtime_ns = launch.config_mtime_ns,
        .theme_locked = options.theme_set,
        .sidebar_renderer_locked = options.sidebar_renderer_set,
        .plugin_registry = launch.plugin_registry,
        .trust_store = launch.trust_store,
        .trust_path = launch.trust_path,
        .profile = if (options.profile) |value| std.mem.span(value) else null,
        .editor = client.configuredEditor(launch.process.minimal.environ),
    };
}

pub fn transferResources(launch: *Launch) void {
    launch.owns_resources = false;
}

pub fn deinit(launch: *Launch) void {
    if (!launch.owns_resources) {
        return;
    }

    if (launch.plugin_registry) |registry| {
        launch.process.gpa.destroy(registry);
    }
    if (launch.trust_store) |store| {
        launch.process.gpa.destroy(store);
    }
    if (launch.generation) |generation| {
        generation.deinit();
    }
    launch.owns_resources = false;
}
