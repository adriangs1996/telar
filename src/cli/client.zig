//! Composition of the interactive Telar client process.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const config = @import("config.zig");
const parser = @import("parser.zig");
const plugin = @import("plugin.zig");
const remote = @import("remote.zig");
const runtime_connection = @import("runtime_connection.zig");

const Io = std.Io;
const RunOptions = parser.RunOptions;
const RuntimeConnector = runtime_connection.RuntimeConnector;
const max_args = backend.pty.max_args;

/// Connects to the local runtime, prepares the selected client configuration
/// and transfers its owned resources into the frontend client lifecycle.
///
/// ```zig
/// const exit_code = try client.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: RunOptions) !u8 {
    var forward: ?remote.Forward = null;
    defer if (forward) |*owned| owned.stop(init.io);
    if (options.remote) |destination| {
        forward = try remote.establish(init, std.mem.span(destination));
    }

    const connector = try RuntimeConnector.init(init, if (forward) |*owned| owned.localPathZ() else null);
    var connection = if (forward != null)
        try remote.connectForwarded(init, &connector)
    else
        try connector.connectOrStart(.{
            .path = options.config,
            .disabled = options.no_config,
            .profile = options.profile,
        });
    defer connection.deinit(init.io);

    var launch: Launch = undefined;
    try launch.prepare(.{
        .process = init,
        .options = &options,
        .endpoint = connector.endpointPath(),
    });
    defer launch.deinit();

    const frontend_options = launch.frontendOptions();
    launch.transferResources();
    return frontend.client.run(init, &connection, frontend_options);
}

const Preparation = struct {
    process: std.process.Init,
    options: *const RunOptions,
    endpoint: []const u8,
};

const Launch = struct {
    process: std.process.Init,
    options: *const RunOptions,
    endpoint: []const u8,
    argument_storage: [max_args][]const u8 = undefined,
    argument_count: usize = 0,
    cwd_buffer: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
    config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    generation: ?*frontend.config.Generation = null,
    config_path: ?[]const u8 = null,
    config_mtime_ns: i128 = 0,
    plugin_registry: ?*frontend.plugins.Registry = null,
    trust_store: ?*core.plugin.TrustStore = null,
    trust_path: ?[]const u8 = null,
    owns_resources: bool = true,

    fn prepare(launch: *Launch, preparation: Preparation) !void {
        launch.* = .{
            .process = preparation.process,
            .options = preparation.options,
            .endpoint = preparation.endpoint,
        };
        errdefer launch.deinit();

        while (preparation.options.command.argv[launch.argument_count]) |argument| : (launch.argument_count += 1) {
            launch.argument_storage[launch.argument_count] = std.mem.span(argument);
        }
        launch.cwd_len = try Io.Dir.cwd().realPathFile(preparation.process.io, ".", &launch.cwd_buffer);
        launch.generation = try config.loadGeneration(preparation.process, .{
            .path = preparation.options.config,
            .disabled = preparation.options.no_config,
            .profile = preparation.options.profile,
        }, &launch.config_path_buffer);
        launch.config_path = if (launch.generation != null)
            if (preparation.options.config) |value|
                std.mem.span(value)
            else
                try frontend.config.defaultPath(preparation.process.minimal.environ, &launch.config_path_buffer)
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

    fn preparePlugins(launch: *Launch, generation: *frontend.config.Generation) !void {
        const resolved_trust_path = try plugin.trustPath(launch.process.minimal.environ, &launch.trust_path_buffer);
        const loaded_trust = try plugin.loadTrustStore(launch.process, resolved_trust_path);
        launch.trust_store = try launch.process.gpa.create(core.plugin.TrustStore);
        launch.trust_store.?.* = loaded_trust;

        const registry_value = try frontend.plugins.Registry.loadWithTrust(
            launch.process.gpa,
            launch.process.io,
            generation.configDir(),
            generation.pluginSlice(),
            launch.trust_store.?,
        );
        try registry_value.validateConfiguredActions(generation.snapshot.bindingSlice());
        launch.plugin_registry = try launch.process.gpa.create(frontend.plugins.Registry);
        launch.plugin_registry.?.* = registry_value;
        launch.config_mtime_ns ^= @as(i128, launch.plugin_registry.?.watchFingerprint(launch.process.gpa, launch.process.io));
        launch.config_mtime_ns ^= @as(i128, frontend.client.trustWatchFingerprint(launch.process.io, resolved_trust_path));
        launch.trust_path = resolved_trust_path;
    }

    fn frontendOptions(launch: *const Launch) frontend.client.Options {
        const snapshot = if (launch.generation) |generation| &generation.snapshot else null;
        const options = launch.options;
        return .{
            .arguments = launch.argument_storage[0..launch.argument_count],
            .cwd = launch.cwd_buffer[0..launch.cwd_len],
            .endpoint = launch.endpoint,
            .prefix = if (snapshot) |value| value.prefix else frontend.keybind.default_prefix,
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
                supportsHostSharedMemory(launch.process.minimal.environ),
            .input_escape_timeout_ns = if (snapshot) |value|
                value.input_escape_timeout_ns
            else
                frontend.keybind.default_escape_timeout_ns,
            .input_sequence_timeout_ns = if (snapshot) |value|
                value.input_sequence_timeout_ns
            else
                frontend.keybind.default_sequence_timeout_ns,
            .lua_generation = launch.generation,
            .config_path = launch.config_path,
            .config_mtime_ns = launch.config_mtime_ns,
            .theme_locked = options.theme_set,
            .sidebar_renderer_locked = options.sidebar_renderer_set,
            .plugin_registry = launch.plugin_registry,
            .trust_store = launch.trust_store,
            .trust_path = launch.trust_path,
            .profile = if (options.profile) |value| std.mem.span(value) else null,
        };
    }

    fn transferResources(launch: *Launch) void {
        launch.owns_resources = false;
    }

    fn deinit(launch: *Launch) void {
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
};

fn supportsHostSharedMemory(environ: std.process.Environ) bool {
    if (environ.getPosix("SSH_CONNECTION") != null) {
        return false;
    }

    const terminal_program = environ.getPosix("TERM_PROGRAM") orelse return false;
    return std.ascii.eqlIgnoreCase(terminal_program, "ghostty");
}

fn testEnvironment(entries: []const struct { []const u8, []const u8 }) !struct {
    map: std.process.Environ.Map,
    block: std.process.Environ.PosixBlock,

    fn deinit(environment: *@This()) void {
        environment.block.deinit(std.testing.allocator);
        environment.map.deinit();
    }
} {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer map.deinit();
    for (entries) |entry| {
        try map.put(entry[0], entry[1]);
    }
    return .{
        .block = try map.createPosixBlock(std.testing.allocator, .{}),
        .map = map,
    };
}

test "local Ghostty clients may use host shared memory" {
    var environment = try testEnvironment(&.{.{ "TERM_PROGRAM", "Ghostty" }});
    defer environment.deinit();

    try std.testing.expect(supportsHostSharedMemory(.{ .block = environment.block }));
}

test "SSH clients never use host shared memory" {
    var environment = try testEnvironment(&.{
        .{ "TERM_PROGRAM", "ghostty" },
        .{ "SSH_CONNECTION", "host 22 host 22" },
    });
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
}

test "other terminals do not use Ghostty shared memory" {
    var environment = try testEnvironment(&.{.{ "TERM_PROGRAM", "iTerm.app" }});
    defer environment.deinit();

    try std.testing.expect(!supportsHostSharedMemory(.{ .block = environment.block }));
    try std.testing.expect(!supportsHostSharedMemory(.empty));
}
