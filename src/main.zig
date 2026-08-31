const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const cli_mod = @import("cli/root.zig");

const Io = std.Io;
const File = Io.File;
const pty = backend.pty;

const version = "0.0.0";

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

const Cli = cli_mod.Cli;
const RunOptions = cli_mod.RunOptions;
const RuntimeConfigSelection = cli_mod.RuntimeConfigSelection;
const RuntimeConnector = cli_mod.RuntimeConnector;
const ServerAction = cli_mod.ServerAction;
const ServerMode = cli_mod.ServerMode;
const ServerOptions = cli_mod.ServerOptions;

fn launchDaemon(
    init: std.process.Init,
    endpoint_path: []const u8,
    graphics: backend.runtime.GraphicsLimits,
    config: RuntimeConfigSelection,
) !void {
    if (std.c.setsid() < 0) return error.DetachFailed;

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var pane_mib_buffer: [32]u8 = undefined;
    const pane_mib = try std.fmt.bufPrint(
        &pane_mib_buffer,
        "{d}",
        .{graphics.pane_bytes / (1024 * 1024)},
    );
    var global_mib_buffer: [32]u8 = undefined;
    const global_mib = try std.fmt.bufPrint(
        &global_mib_buffer,
        "{d}",
        .{graphics.global_bytes / (1024 * 1024)},
    );
    var argv: [13][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{
        executable,
        "server",
        "--daemonized",
        "--socket",
        endpoint_path,
        "--graphics-pane-mib",
        pane_mib,
        "--graphics-global-mib",
        global_mib,
    }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    if (config.path) |path| {
        argv[argc] = "--config";
        argv[argc + 1] = std.mem.span(path);
        argc += 2;
    } else if (config.disabled) {
        argv[argc] = "--no-config";
        argc += 1;
    }
    if (config.profile) |profile| {
        argv[argc] = "--profile";
        argv[argc + 1] = std.mem.span(profile);
        argc += 2;
    }
    const daemon = try std.process.spawn(init.io, .{
        .argv = argv[0..argc],
        .cwd = .{ .path = "/" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = daemon;
}

const HistoryPath = struct {
    path: [:0]const u8,
    managed_directory: ?[]const u8,
};

fn resolveProxyDirectory(init: std.process.Init, buffer: []u8) ![]const u8 {
    const base = if (std.process.Environ.getPosix(init.minimal.environ, "XDG_DATA_HOME")) |path|
        if (path.len != 0) path else null
    else
        null;
    if (base) |data_home| return std.fmt.bufPrint(buffer, "{s}/telar/proxy", .{data_home});
    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse
        return error.HomeDirectoryUnavailable;
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/proxy", .{home});
}

fn prepareProxyDirectory(io: Io, directory: []const u8) !void {
    const permissions = File.Permissions.fromMode(0o700);
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidProxyDirectory;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch
        return error.NameTooLong;
    var native_stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &native_stat, std.c.AT.SYMLINK_NOFOLLOW) != 0)
        return error.InvalidProxyDirectory;
    if (native_stat.uid != std.c.getuid()) return error.WrongOwner;
    try Io.Dir.cwd().setFilePermissions(
        io,
        directory,
        permissions,
        .{ .follow_symlinks = false },
    );
}

fn resolveHistoryPath(
    init: std.process.Init,
    buffer: []u8,
) !HistoryPath {
    if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_HISTORY")) |path| {
        if (path.len != 0) return .{
            .path = try std.fmt.bufPrintZ(buffer, "{s}", .{path}),
            .managed_directory = null,
        };
    }

    const base = if (std.process.Environ.getPosix(init.minimal.environ, "XDG_DATA_HOME")) |path|
        if (path.len != 0) path else null
    else
        null;
    if (base) |data_home| {
        const directory = try std.fmt.bufPrint(buffer, "{s}/telar", .{data_home});
        const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
        return .{
            .path = buffer[0 .. directory.len + path.len :0],
            .managed_directory = directory,
        };
    }

    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse
        return error.HomeDirectoryUnavailable;
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    const directory = try std.fmt.bufPrint(buffer, "{s}/.local/share/telar", .{home});
    const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
    return .{
        .path = buffer[0 .. directory.len + path.len :0],
        .managed_directory = directory,
    };
}

fn prepareHistoryDatabase(io: Io, history_path: HistoryPath) !void {
    if (history_path.managed_directory) |directory| {
        const permissions = File.Permissions.fromMode(0o700);
        _ = try Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
        try Io.Dir.cwd().setFilePermissions(
            io,
            directory,
            permissions,
            .{ .follow_symlinks = false },
        );
    }
    const file = try Io.Dir.createFileAbsolute(io, history_path.path, .{
        .read = true,
        .truncate = false,
        .permissions = File.Permissions.fromMode(0o600),
    });
    file.close(io);
    try Io.Dir.cwd().setFilePermissions(
        io,
        history_path.path,
        File.Permissions.fromMode(0o600),
        .{ .follow_symlinks = false },
    );
}

fn runServer(init: std.process.Init, options: ServerOptions) !void {
    var resolved_options = options;
    var configured_history_path: ?[:0]const u8 = null;
    var configured_history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var proxy_enabled = false;
    var configured_proxy_directory: ?[]u8 = null;
    var proxy_passthrough_host_storage: [frontend.config.max_proxy_passthrough_hosts][]const u8 = undefined;
    var proxy_passthrough_hosts: []const []const u8 = &.{};
    var description_arguments: [frontend.config.max_agent_description_command_args][]const u8 = undefined;
    var agent_description_options: ?backend.runtime.AgentDescriptionOptions = null;
    defer if (configured_proxy_directory) |directory| init.gpa.free(directory);
    const connector = try RuntimeConnector.init(init, options.socket);
    if (options.action == .stop) return stopRuntime(init, &connector);

    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_generation = try cli_mod.config.loadGeneration(init, .{
        .path = options.config,
        .disabled = options.no_config,
        .profile = options.profile,
    }, &config_path_buffer);
    defer if (config_generation) |generation| generation.deinit();
    if (config_generation) |generation| {
        if (!resolved_options.graphics_pane_set)
            resolved_options.graphics.pane_bytes = generation.snapshot.runtime.graphics_pane_bytes;
        if (!resolved_options.graphics_global_set)
            resolved_options.graphics.global_bytes = generation.snapshot.runtime.graphics_global_bytes;
        if (generation.snapshot.runtime.historyPath()) |history_path| {
            const resolved = if (std.fs.path.isAbsolute(history_path))
                try init.gpa.dupe(u8, history_path)
            else
                try std.fs.path.resolve(init.gpa, &.{ generation.configDir(), history_path });
            defer init.gpa.free(resolved);
            configured_history_path = try std.fmt.bufPrintZ(
                &configured_history_buffer,
                "{s}",
                .{resolved},
            );
        }
        proxy_enabled = generation.snapshot.runtime.proxy_enabled;
        proxy_passthrough_hosts = generation.snapshot.runtime.proxyPassthroughHosts(
            &proxy_passthrough_host_storage,
        );
        if (proxy_enabled) if (generation.snapshot.runtime.proxyCaDir()) |ca_dir| {
            configured_proxy_directory = if (std.fs.path.isAbsolute(ca_dir))
                try init.gpa.dupe(u8, ca_dir)
            else
                try std.fs.path.resolve(init.gpa, &.{ generation.configDir(), ca_dir });
        };
        const description_command = &generation.snapshot.runtime.agent_descriptions;
        if (description_command.enabled()) agent_description_options = .{
            .arguments = description_command.arguments(&description_arguments),
            .timeout_ms = description_command.timeout_ms,
        };
    }
    try resolved_options.graphics.validate();

    switch (resolved_options.mode) {
        .background_launcher => return launchDaemon(init, connector.endpointPath(), resolved_options.graphics, .{
            .path = resolved_options.config,
            .disabled = resolved_options.no_config,
            .profile = resolved_options.profile,
        }),
        .foreground, .daemonized => {},
    }

    try connector.prepareServerDirectory();
    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_path: HistoryPath = if (configured_history_path) |path|
        .{ .path = path, .managed_directory = null }
    else
        try resolveHistoryPath(init, &history_buffer);
    try prepareHistoryDatabase(init.io, history_path);
    var default_proxy_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const proxy_directory = if (proxy_enabled)
        configured_proxy_directory orelse try init.gpa.dupe(
            u8,
            try resolveProxyDirectory(init, &default_proxy_buffer),
        )
    else
        null;
    defer if (proxy_enabled and configured_proxy_directory == null)
        init.gpa.free(proxy_directory.?);
    var proxy_key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var proxy_cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var proxy_bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const proxy_options: ?backend.runtime.ProxyOptions = if (proxy_directory) |directory| block: {
        try prepareProxyDirectory(init.io, directory);
        break :block .{
            .key_path = try std.fmt.bufPrint(&proxy_key_buffer, "{s}/ca-key.pem", .{directory}),
            .certificate_path = try std.fmt.bufPrint(&proxy_cert_buffer, "{s}/ca-cert.pem", .{directory}),
            .bundle_path = try std.fmt.bufPrint(&proxy_bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
            .passthrough_hosts = proxy_passthrough_hosts,
        };
    } else null;
    var runtime: backend.runtime.Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{
            .io = init.io,
            .allocator = init.gpa,
        },
        .options = .{
            .endpoint = connector.endpointPath(),
            .graphics = resolved_options.graphics,
            .environment = init.minimal.environ,
            .history_path = history_path.path,
            .proxy = proxy_options,
            .agent_descriptions = agent_description_options,
        },
    });
    defer runtime.deinit();

    try runtime.run();
}

fn stopRuntime(init: std.process.Init, connector: *const RuntimeConnector) !void {
    var connection = connector.connect() catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            try File.stdout().writeStreamingAll(init.io, "telar runtime is not running\n");
            return;
        },
        else => |other| return other,
    };
    defer connection.deinit(init.io);

    var send_buffer: [1]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeRuntimeStop(&send_buffer));

    var receive_buffer: [2048]u8 = undefined;
    switch (try core.schema.decodeServer(try connection.receive(init.io, &receive_buffer))) {
        .runtime_stopping => try File.stdout().writeStreamingAll(init.io, "telar runtime stopped\n"),
        .request_failed => |failure| {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.RuntimeRequestFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn collectArgs(init: std.process.Init, storage: *[pty.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) return error.TooManyArguments;
        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

fn runClient(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: *const RunOptions,
    endpoint: []const u8,
) !u8 {
    var argument_storage: [pty.max_args][]const u8 = undefined;
    var argument_count: usize = 0;
    while (options.command.argv[argument_count]) |argument| : (argument_count += 1) {
        argument_storage[argument_count] = std.mem.span(argument);
    }

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const generation = try cli_mod.config.loadGeneration(init, .{
        .path = options.config,
        .disabled = options.no_config,
        .profile = options.profile,
    }, &config_path_buffer);
    const config_path: ?[]const u8 = if (generation != null)
        if (options.config) |value|
            std.mem.span(value)
        else
            try frontend.config.defaultPath(init.minimal.environ, &config_path_buffer)
    else
        null;
    var config_mtime_ns = if (config_path) |path|
        generation.?.watchFingerprint(init.io, path)
    else
        0;
    const snapshot = if (generation) |value| &value.snapshot else null;
    var plugin_registry: ?*frontend.plugins.Registry = null;
    var trust_store: ?*core.plugin.TrustStore = null;
    var trust_path: ?[]const u8 = null;
    if (generation) |value| {
        var trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_trust_path = cli_mod.plugin.trustPath(
            init.minimal.environ,
            &trust_path_buffer,
        ) catch |err| {
            value.deinit();
            return err;
        };
        const loaded_trust = cli_mod.plugin.loadTrustStore(
            init,
            resolved_trust_path,
        ) catch |err| {
            value.deinit();
            return err;
        };
        trust_store = init.gpa.create(core.plugin.TrustStore) catch |err| {
            value.deinit();
            return err;
        };
        trust_store.?.* = loaded_trust;
        const registry_value = frontend.plugins.Registry.loadWithTrust(
            init.gpa,
            init.io,
            value.configDir(),
            value.pluginSlice(),
            trust_store.?,
        ) catch |err| {
            init.gpa.destroy(trust_store.?);
            value.deinit();
            return err;
        };
        registry_value.validateConfiguredActions(value.snapshot.bindingSlice()) catch |err| {
            init.gpa.destroy(trust_store.?);
            value.deinit();
            return err;
        };
        plugin_registry = init.gpa.create(frontend.plugins.Registry) catch |err| {
            init.gpa.destroy(trust_store.?);
            value.deinit();
            return err;
        };
        plugin_registry.?.* = registry_value;
        config_mtime_ns ^= @as(i128, plugin_registry.?.watchFingerprint(init.gpa, init.io));
        config_mtime_ns ^= @as(i128, frontend.client.trustWatchFingerprint(init.io, resolved_trust_path));
        trust_path = resolved_trust_path;
    }
    return frontend.client.run(init, connection, .{
        .arguments = argument_storage[0..argument_count],
        .cwd = cwd_buffer[0..cwd_len],
        .endpoint = endpoint,
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
        .host_shared_memory = init.minimal.environ.getPosix("SSH_CONNECTION") == null and
            if (init.minimal.environ.getPosix("TERM_PROGRAM")) |program|
                std.ascii.eqlIgnoreCase(program, "ghostty")
            else
                false,
        .input_escape_timeout_ns = if (snapshot) |value|
            value.input_escape_timeout_ns
        else
            frontend.keybind.default_escape_timeout_ns,
        .input_sequence_timeout_ns = if (snapshot) |value|
            value.input_sequence_timeout_ns
        else
            frontend.keybind.default_sequence_timeout_ns,
        .lua_generation = generation,
        .config_path = config_path,
        .config_mtime_ns = config_mtime_ns,
        .theme_locked = options.theme_set,
        .sidebar_renderer_locked = options.sidebar_renderer_set,
        .plugin_registry = plugin_registry,
        .trust_store = trust_store,
        .trust_path = trust_path,
        .profile = if (options.profile) |value| std.mem.span(value) else null,
    });
}

const usage =
    \\Usage: telar [--config PATH | --no-config] [--profile NAME] [--theme NAME] [--sidebar-renderer MODE] [command [args...]]
    \\       telar server
    \\       telar server stop
    \\       telar config check [PATH] [--profile NAME]
    \\       telar plugin inspect PATH
    \\       telar plugin install PATH
    \\       telar plugin trust PATH [--capability NAME]...
    \\       telar history list [options]
    \\       telar history search <query> [options]
    \\       telar notification show <title> [options]
    \\
    \\Run an interactive shell inside telar's multiplexer UI.
    \\With a command, run that command instead of $SHELL.
    \\The local runtime starts automatically when needed.
    \\
    \\Commands:
    \\  server           Run the local runtime in the foreground
    \\  server stop      Stop the local runtime
    \\  history list     Show recent command history
    \\  history search   Search command history
    \\  notification show  Show a toast in every connected UI client
    \\  config check     Compile and validate config.lua, then exit
    \\  plugin inspect   Validate a package and print its immutable identity
    \\  plugin install   Copy a package into the content-addressed local store
    \\  plugin trust     Grant declared capabilities to one exact package digest
    \\
    \\History options:
    \\  --cwd            Restrict results to the current directory
    \\  --workspace PATH Restrict results to a workspace path
    \\  --pane ID        Restrict results to a pane
    \\  --failed         Only show commands with a non-zero exit status
    \\  --limit N        Return at most N results (default 20, maximum 100)
    \\  --socket PATH    Query a specific local runtime
    \\
    \\Notification options:
    \\  --body TEXT      Add detail text below the title
    \\  --level LEVEL    info, success, warning, or failure
    \\  --duration MS    Keep it visible for 500..60000 ms (default 4000)
    \\  --pane ID        Make it focus a pane when clicked
    \\  --tab ID         Make it select a tab when clicked
    \\  --workspace ID   Make it select a workspace when clicked
    \\  --socket PATH    Notify clients of a specific local runtime
    \\
    \\Options:
    \\  --config PATH     Load a specific Lua configuration
    \\  --no-config       Do not load Lua configuration
    \\  --profile NAME    Overlay a named Lua profile before CLI options
    \\  --theme NAME      UI theme: vesper, catppuccin, tokyo-night, terminal
    \\  --sidebar-renderer MODE  automatic, cells, kitty-hybrid, kitty-full
    \\Server options:
    \\  --graphics-pane-mib N    Decoded KGP memory per pane (default 64)
    \\  --graphics-global-mib N  Decoded KGP memory for the runtime (default 256)
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  --               Stop parsing telar options
    \\
    \\Default keybindings (prefix Ctrl-b):
    \\  % / "             Split left/right or top/bottom
    \\  Arrow keys       Focus a pane by direction
    \\  Shift+arrows     Resize the focused pane
    \\  z                Toggle pane fullscreen
    \\  s                Toggle the sidebar
    \\  w                Toggle the workspace list
    \\  N                Create and select a workspace
    \\  W                Rename the active workspace
    \\  x                Close the focused pane
    \\  [                Enter copy mode
    \\  c                Create and select a tab
    \\  n / p            Select the next or previous tab
    \\  1..9             Select a tab by position
    \\  T                Rename the active tab
    \\  X                Close the active tab
    \\  , / .            Move the active tab left or right
    \\  d                Detach the client
    \\
;

pub fn main(init: std.process.Init) !void {
    var arg_storage: [pty.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try Cli.parse(args, init.minimal.environ)) {
        .help => try File.stdout().writeStreamingAll(init.io, usage),
        .version => try File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try runServer(init, options),
        .history => |options| try cli_mod.history.run(init, options),
        .notification => |options| try cli_mod.notification.run(init, options),
        .config_check => |options| try cli_mod.config.runCheck(init, options),
        .plugin_worker => |options| try frontend.plugins.runWorker(
            init,
            std.mem.span(options.entry),
            std.mem.span(options.action),
            options.context,
        ),
        .plugin => |options| try cli_mod.plugin.run(init, options),
        .run => |options| {
            const connector = try RuntimeConnector.init(init, null);
            var connection = try connector.connectOrStart(.{
                .path = options.config,
                .disabled = options.no_config,
                .profile = options.profile,
            });
            defer connection.deinit(init.io);

            const code = try runClient(init, &connection, &options, connector.endpointPath());
            std.process.exit(code);
        },
    }
}
