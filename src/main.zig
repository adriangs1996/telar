const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const cli_mod = @import("cli.zig");

const Io = std.Io;
const File = Io.File;
const pty = backend.pty;

const version = "0.0.0";
const runtime_start_attempts = 200;
const runtime_start_interval_ms = 10;

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

const Cli = cli_mod.Cli;
const ConfigCheckOptions = cli_mod.ConfigCheckOptions;
const HistoryAction = cli_mod.HistoryAction;
const HistoryOptions = cli_mod.HistoryOptions;
const PluginCommand = cli_mod.PluginCommand;
const PluginOptions = cli_mod.PluginOptions;
const RunOptions = cli_mod.RunOptions;
const ServerAction = cli_mod.ServerAction;
const ServerMode = cli_mod.ServerMode;
const ServerOptions = cli_mod.ServerOptions;
fn resolveEndpoint(
    init: std.process.Init,
    override: ?[*:0]const u8,
) !core.endpoint.Local {
    if (override) |path| return core.endpoint.Local.explicit(std.mem.span(path));

    if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_SOCKET")) |path| {
        if (path.len != 0) return core.endpoint.Local.explicit(path);
    }

    if (std.process.Environ.getPosix(init.minimal.environ, "XDG_RUNTIME_DIR")) |base| {
        if (base.len != 0) return core.endpoint.Local.managed(base, "telar");
    }

    var directory_name_buffer: [32]u8 = undefined;
    const directory_name = try std.fmt.bufPrint(
        &directory_name_buffer,
        "telar-{d}",
        .{std.c.getuid()},
    );
    if (std.process.Environ.getPosix(init.minimal.environ, "TMPDIR")) |base| {
        if (base.len != 0) return core.endpoint.Local.managed(base, directory_name);
    }
    return core.endpoint.Local.managed("/tmp", directory_name);
}

fn prepareManagedDirectory(io: Io, endpoint: *const core.endpoint.Local) !void {
    const directory = endpoint.managedDirectory() orelse return;
    const permissions = File.Permissions.fromMode(0o700);
    Io.Dir.createDirAbsolute(io, directory, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return other,
    };

    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidRuntimeDirectory;

    // Socket directories reject wrong owners explicitly instead of relying on
    // a later chmod failing with EPERM. `Io.File.Stat` carries no uid, so ask
    // libc directly.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch
        return error.NameTooLong;
    var native_stat: std.c.Stat = undefined;
    if (std.c.fstatat(
        std.c.AT.FDCWD,
        directory_z,
        &native_stat,
        std.c.AT.SYMLINK_NOFOLLOW,
    ) != 0) return error.InvalidRuntimeDirectory;
    try checkRuntimeDirectoryOwner(native_stat.uid, std.c.getuid());

    try Io.Dir.cwd().setFilePermissions(
        io,
        directory,
        permissions,
        .{ .follow_symlinks = false },
    );
}

fn checkRuntimeDirectoryOwner(owner: std.c.uid_t, me: std.c.uid_t) error{WrongOwner}!void {
    if (owner != me) return error.WrongOwner;
}

fn executablePath(io: Io, buffer: []u8) ![]const u8 {
    return buffer[0..try std.process.executablePath(io, buffer)];
}

fn launchDaemon(
    init: std.process.Init,
    endpoint: *const core.endpoint.Local,
    graphics: backend.runtime.GraphicsLimits,
    config: RuntimeConfigSelection,
) !void {
    if (std.c.setsid() < 0) return error.DetachFailed;

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try executablePath(init.io, &executable_buffer);
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
        endpoint.path(),
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

const RuntimeConfigSelection = struct {
    path: ?[*:0]const u8 = null,
    disabled: bool = false,
    profile: ?[*:0]const u8 = null,
};

fn startRuntime(
    init: std.process.Init,
    endpoint: *const core.endpoint.Local,
    config: RuntimeConfigSelection,
) !void {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try executablePath(init.io, &executable_buffer);
    var argv: [9][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ executable, "server", "--background", "--socket", endpoint.path() }) |arg| {
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
    var launcher = try std.process.spawn(init.io, .{
        .argv = argv[0..argc],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const result = try launcher.wait(init.io);
    switch (result) {
        .exited => |status| if (status != 0) return error.RuntimeStartFailed,
        else => return error.RuntimeStartFailed,
    }
}

fn finishHandshake(io: Io, connection: core.transport.SocketChannel) !core.transport.SocketChannel {
    var result = connection;
    errdefer result.deinit(io);

    const response = try frontend.transport.handshake.perform(io, &result);
    switch (response) {
        .accepted => return result,
        .rejected => |rejected| {
            std.debug.print(
                "telar protocol mismatch: runtime expects schema {s}\n",
                .{&rejected.expected_schema},
            );
            return error.IncompatibleSchema;
        },
    }
}

fn connectRuntime(
    init: std.process.Init,
    endpoint: *const core.endpoint.Local,
    config: RuntimeConfigSelection,
) !core.transport.SocketChannel {
    const first = frontend.transport.local.connect(init.io, endpoint.path()) catch |err| switch (err) {
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        error.RelativePath,
        error.NameTooLong,
        => return err,
        else => null,
    };
    if (first) |connection| return finishHandshake(init.io, connection);

    try prepareManagedDirectory(init.io, endpoint);
    try startRuntime(init, endpoint, config);
    for (0..runtime_start_attempts) |_| {
        if (frontend.transport.local.connect(init.io, endpoint.path())) |connection| {
            return finishHandshake(init.io, connection);
        } else |_| {
            init.io.sleep(.fromMilliseconds(runtime_start_interval_ms), .awake) catch {};
        }
    }
    return error.RuntimeUnavailable;
}

const HistoryPath = struct {
    path: [:0]const u8,
    managed_directory: ?[]const u8,
};

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
    const endpoint = try resolveEndpoint(init, options.socket);
    if (options.action == .stop) return stopRuntime(init, &endpoint);

    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (try loadConfigGeneration(
        init,
        options.config,
        options.no_config,
        options.profile,
        &config_path_buffer,
    )) |generation| {
        defer generation.deinit();
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
    }
    try resolved_options.graphics.validate();

    switch (resolved_options.mode) {
        .background_launcher => return launchDaemon(init, &endpoint, resolved_options.graphics, .{
            .path = resolved_options.config,
            .disabled = resolved_options.no_config,
            .profile = resolved_options.profile,
        }),
        .foreground, .daemonized => {},
    }

    try prepareManagedDirectory(init.io, &endpoint);
    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_path: HistoryPath = if (configured_history_path) |path|
        .{ .path = path, .managed_directory = null }
    else
        try resolveHistoryPath(init, &history_buffer);
    try prepareHistoryDatabase(init.io, history_path);
    try backend.runtime.serve(
        init.io,
        init.gpa,
        endpoint.path(),
        .{
            .graphics = resolved_options.graphics,
            .environment = init.minimal.environ,
            .history_path = history_path.path,
        },
    );
}

fn stopRuntime(init: std.process.Init, endpoint: *const core.endpoint.Local) !void {
    const raw_connection = frontend.transport.local.connect(init.io, endpoint.path()) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            try File.stdout().writeStreamingAll(init.io, "telar runtime is not running\n");
            return;
        },
        else => |other| return other,
    };
    var connection = try finishHandshake(init.io, raw_connection);
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
    const generation = try loadConfigGeneration(
        init,
        options.config,
        options.no_config,
        options.profile,
        &config_path_buffer,
    );
    const config_path: ?[]const u8 = if (generation != null)
        if (options.config) |value|
            std.mem.span(value)
        else
            try frontend.lua_config.defaultPath(init.minimal.environ, &config_path_buffer)
    else
        null;
    var config_mtime_ns = if (config_path) |path|
        generation.?.watchFingerprint(init.io, path)
    else
        0;
    const snapshot = if (generation) |value| &value.snapshot else null;
    var plugin_registry: ?*frontend.plugin_broker.Registry = null;
    var trust_store: ?*core.plugin.TrustStore = null;
    var trust_path: ?[]const u8 = null;
    if (generation) |value| {
        var trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_trust_path = resolveTrustPath(
            init.minimal.environ,
            &trust_path_buffer,
        ) catch |err| {
            value.deinit();
            return err;
        };
        const loaded_trust = loadTrustStore(
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
        const registry_value = frontend.plugin_broker.Registry.loadWithTrust(
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
        plugin_registry = init.gpa.create(frontend.plugin_broker.Registry) catch |err| {
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
        .bindings = if (snapshot) |value| value.bindingSlice() else &.{},
        .bindings_configured = if (snapshot) |value| value.bindings_configured else false,
        .theme = if (options.theme_set)
            options.theme
        else if (snapshot) |value|
            value.theme
        else
            options.theme,
        .sidebar_rendering = if (options.sidebar_renderer_set)
            options.sidebar_rendering
        else if (snapshot) |value|
            value.sidebar_rendering
        else
            options.sidebar_rendering,
        .sidebar_visible = if (snapshot) |value| value.sidebar_visible else true,
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

fn loadConfigGeneration(
    init: std.process.Init,
    override: ?[*:0]const u8,
    disabled: bool,
    profile: ?[*:0]const u8,
    path_buffer: []u8,
) !?*frontend.lua_config.Generation {
    if (disabled) return null;
    const explicit = override != null or profile != null;
    const path = if (override) |value|
        std.mem.span(value)
    else
        try frontend.lua_config.defaultPath(init.minimal.environ, path_buffer);
    Io.Dir.cwd().access(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => if (explicit) return err else return null,
        else => |other| return other,
    };
    var diagnostic: frontend.lua_config.Diagnostic = .{};
    return frontend.lua_config.Generation.loadFileProfile(
        init.gpa,
        init.io,
        path,
        1,
        if (profile) |value| std.mem.span(value) else null,
        &diagnostic,
    ) catch |err| {
        std.debug.print("telar config: {s}\n", .{diagnostic.message()});
        return err;
    };
}

fn runConfigCheck(init: std.process.Init, options: ConfigCheckOptions) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (options.path) |value|
        std.mem.span(value)
    else
        try frontend.lua_config.defaultPath(init.minimal.environ, &path_buffer);
    var diagnostic: frontend.lua_config.Diagnostic = .{};
    const generation = frontend.lua_config.Generation.loadFileProfile(
        init.gpa,
        init.io,
        path,
        1,
        if (options.profile) |value| std.mem.span(value) else null,
        &diagnostic,
    ) catch |err| {
        std.debug.print("telar config: {s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();
    const registry = try frontend.plugin_broker.Registry.load(
        init.gpa,
        init.io,
        generation.configDir(),
        generation.pluginSlice(),
    );
    try registry.validateConfiguredActions(generation.snapshot.bindingSlice());
    try File.stdout().writeStreamingAll(init.io, "telar config: OK\n");
}

fn runPluginCommand(init: std.process.Init, options: PluginOptions) !void {
    const package = try frontend.plugin_broker.inspectPackage(
        init.gpa,
        init.io,
        std.mem.span(options.path),
    );
    switch (options.command) {
        .inspect => {
            var buffer: [4096]u8 = undefined;
            var output = File.stdout().writerStreaming(init.io, &buffer);
            const writer = &output.interface;
            try writer.print("id: {s}\nversion: {s}\nsource: {s}\nrevision: {s}\ndigest: ", .{
                package.manifest.id(),
                package.manifest.version(),
                package.manifest.source(),
                package.manifest.revision(),
            });
            for (package.digest) |byte| try writer.print("{x:0>2}", .{byte});
            try writer.writeAll("\nactions:");
            for (package.manifest.actions[0..package.manifest.action_count]) |*action|
                try writer.print(" {s}", .{action.slice()});
            try writer.writeAll("\ncapabilities:");
            var iterator = package.manifest.capabilities.iterator();
            while (iterator.next()) |capability|
                try writer.print(" {s}", .{capability.canonicalName()});
            try writer.writeByte('\n');
            try writer.flush();
        },
        .install => {
            var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const base = try resolvePluginInstallBase(init.minimal.environ, &base_buffer);
            const digest_hex = std.fmt.bytesToHex(package.digest, .lower);
            var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const destination = try std.fmt.bufPrint(
                &destination_buffer,
                "{s}/{s}/{s}",
                .{ base, package.manifest.id(), &digest_hex },
            );
            try frontend.plugin_broker.installPackage(
                init.gpa,
                init.io,
                &package,
                destination,
            );
            var output_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
            const output = try std.fmt.bufPrint(
                &output_buffer,
                "telar plugin installed: {s}\n",
                .{destination},
            );
            try File.stdout().writeStreamingAll(init.io, output);
        },
        .trust => {
            var granted = core.plugin.CapabilitySet.initEmpty();
            if (options.capability_count == 0) {
                granted = package.manifest.capabilities;
            } else for (options.capabilities[0..options.capability_count]) |capability| {
                if (!package.manifest.capabilities.contains(capability))
                    return error.CapabilityNotDeclared;
                if (granted.contains(capability)) return error.DuplicateCapability;
                granted.insert(capability);
            }
            var trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const trust_path = try resolveTrustPath(init.minimal.environ, &trust_path_buffer);
            var store = try loadTrustStore(init, trust_path);
            try store.upsert(&package.manifest, package.digest, granted);
            try writeTrustStore(init, trust_path, &store);
            try File.stdout().writeStreamingAll(init.io, "telar plugin trust updated\n");
        },
    }
}

fn resolvePluginInstallBase(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) return std.fmt.bufPrint(buffer, "{s}/telar/plugins", .{base});
    }
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/plugins", .{home});
}

fn resolveTrustPath(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |base| {
        if (base.len != 0) return std.fmt.bufPrint(buffer, "{s}/telar/trust.json", .{base});
    }
    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.config/telar/trust.json", .{home});
}

fn loadTrustStore(init: std.process.Init, path: []const u8) !core.plugin.TrustStore {
    const stat = Io.Dir.cwd().statFile(init.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |other| return other,
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureTrustStore;
    const source = try Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024));
    defer init.gpa.free(source);
    return core.plugin.TrustStore.parse(init.gpa, source);
}

fn writeTrustStore(
    init: std.process.Init,
    path: []const u8,
    store: *const core.plugin.TrustStore,
) !void {
    const directory = std.fs.path.dirname(path) orelse return error.InvalidTrustStorePath;
    _ = try Io.Dir.cwd().createDirPathStatus(
        init.io,
        directory,
        File.Permissions.fromMode(0o700),
    );
    try Io.Dir.cwd().setFilePermissions(
        init.io,
        directory,
        File.Permissions.fromMode(0o700),
        .{ .follow_symlinks = false },
    );
    var nonce: [16]u8 = undefined;
    try init.io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(
        &temp_buffer,
        "{s}.tmp-{s}",
        .{ path, &nonce_hex },
    );
    var committed = false;
    defer if (!committed) Io.Dir.cwd().deleteFile(init.io, temp) catch {};
    var file = try Io.Dir.cwd().createFile(init.io, temp, .{
        .truncate = true,
        .permissions = File.Permissions.fromMode(0o600),
    });
    var file_open = true;
    defer if (file_open) file.close(init.io);
    var output_buffer: [4096]u8 = undefined;
    var output = file.writer(init.io, &output_buffer);
    try store.writeJson(&output.interface);
    try output.interface.flush();
    try file.sync(init.io);
    file.close(init.io);
    file_open = false;
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, init.io);
    committed = true;
}

fn runHistory(init: std.process.Init, options: HistoryOptions) !void {
    const endpoint = try resolveEndpoint(init, options.socket);
    var connection = try connectRuntime(init, &endpoint, .{});
    defer connection.deinit(init.io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const query = if (options.query) |value| std.mem.span(value) else "";

    var send_buffer: [schema_history_request_size]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeQueryHistory(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .query = query,
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .failed_only = options.failed_only,
        .limit = options.limit,
    }));

    const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.schema.decodeServer(
        try connection.receive(init.io, receive_buffer),
    );
    switch (response) {
        .history_results => |results| try printHistory(init.io, results),
        .request_failed => |failure| {
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

const schema_history_request_size = core.schema.max_history_query_bytes +
    core.schema.max_cwd_bytes + 64;

fn printHistory(io: Io, results: core.schema.HistoryResultsView) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(io, &output_buffer);
    const writer = &output.interface;
    var entries = results.entries();
    while (try entries.next()) |entry| {
        const timestamp = utcTimestamp(entry.started_at_ms);
        try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z  ",
            .{
                timestamp.year,
                timestamp.month,
                timestamp.day,
                timestamp.hour,
                timestamp.minute,
                timestamp.second,
            },
        );
        switch (entry.status) {
            .interrupted => try writer.writeAll("INT  "),
            .completed => if (entry.exit_code) |exit_code| {
                if (exit_code < 0)
                    try writer.print("-{d}  ", .{@as(u64, @intCast(-@as(i64, exit_code)))})
                else
                    try writer.print("{d}  ", .{@as(u32, @intCast(exit_code))});
            } else {
                try writer.writeAll("?  ");
            },
        }
        const duration_ms: u64 = @intCast(@max(
            @as(i64, 0),
            @divTrunc(entry.duration_ns, std.time.ns_per_ms),
        ));
        try writer.print("{d}ms  ", .{duration_ms});
        try writeHistoryField(writer, entry.cwd);
        try writer.writeAll("  ");
        try writeHistoryField(writer, entry.command);
        try writer.writeByte('\n');
    }
    try writer.flush();
}

const UtcTimestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn utcTimestamp(milliseconds: i64) UtcTimestamp {
    const seconds: u64 = @intCast(@max(@as(i64, 0), @divFloor(milliseconds, 1000)));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

fn writeHistoryField(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f)
            try writer.print("\\x{x:0>2}", .{byte})
        else
            try writer.writeByte(byte),
    };
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
    \\  s                Toggle the sidebar
    \\  x                Close the focused pane
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
        .history => |options| try runHistory(init, options),
        .config_check => |options| try runConfigCheck(init, options),
        .plugin_worker => |options| try frontend.plugin_worker.run(
            init,
            std.mem.span(options.entry),
            std.mem.span(options.action),
            options.context,
        ),
        .plugin => |options| try runPluginCommand(init, options),
        .run => |options| {
            const endpoint = try resolveEndpoint(init, null);
            var connection = try connectRuntime(init, &endpoint, .{
                .path = options.config,
                .disabled = options.no_config,
                .profile = options.profile,
            });
            defer connection.deinit(init.io);

            const code = try runClient(init, &connection, &options, endpoint.path());
            std.process.exit(code);
        },
    }
}

test "CLI defaults to the configured shell" {
    const args = [_][*:0]const u8{"telar"};
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .run);
    try std.testing.expect(cli.run.command.argv[0] != null);
    try std.testing.expectEqual(frontend.theme.Builtin.vesper, cli.run.theme.base);
}

test "CLI forwards a command without a shell" {
    const args = [_][*:0]const u8{ "telar", "/bin/sh", "-c", "exit 9" };
    const cli = try Cli.parse(&args, .empty);

    try std.testing.expect(cli == .run);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
    try std.testing.expectEqualStrings("exit 9", std.mem.span(cli.run.command.argv[2].?));
}

test "CLI delimiter permits option-shaped commands" {
    const args = [_][*:0]const u8{ "telar", "--", "-command" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqualStrings("-command", std.mem.span(cli.run.command.file));
}

test "CLI selects a built-in theme before the command" {
    const args = [_][*:0]const u8{ "telar", "--theme=catppuccin", "/bin/sh" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.theme.Builtin.catppuccin, cli.run.theme.base);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
}

test "CLI runs the default shell when only a theme is provided" {
    const args = [_][*:0]const u8{ "telar", "--theme", "tokyonight" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.theme.Builtin.tokyo_night, cli.run.theme.base);
    try std.testing.expect(cli.run.command.argv[0] != null);
}

test "CLI rejects unknown and duplicate themes" {
    const unknown = [_][*:0]const u8{ "telar", "--theme", "neon" };
    try std.testing.expectError(error.UnknownTheme, Cli.parse(&unknown, .empty));

    const duplicate = [_][*:0]const u8{
        "telar",
        "--theme",
        "vesper",
        "--theme=catppuccin",
    };
    try std.testing.expectError(error.DuplicateThemeOption, Cli.parse(&duplicate, .empty));
}

test "CLI selects and validates the sidebar renderer" {
    const args = [_][*:0]const u8{ "telar", "--sidebar-renderer=kitty-hybrid", "/bin/sh" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.kitty.SidebarRendering.kitty_hybrid, cli.run.sidebar_rendering);

    const invalid = [_][*:0]const u8{ "telar", "--sidebar-renderer", "sixel" };
    try std.testing.expectError(error.UnknownSidebarRenderer, Cli.parse(&invalid, .empty));
}

test "CLI rejects an empty command after the delimiter" {
    const args = [_][*:0]const u8{ "telar", "--" };
    try std.testing.expectError(error.MissingCommand, Cli.parse(&args, .empty));
}

test "CLI parses config profiles and rejects profile without config" {
    const args = [_][*:0]const u8{ "telar", "--config", "config.lua", "--profile", "remote" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqualStrings("remote", std.mem.span(cli.run.profile.?));

    const disabled = [_][*:0]const u8{ "telar", "--no-config", "--profile", "remote" };
    try std.testing.expectError(error.ProfileWithoutConfig, Cli.parse(&disabled, .empty));

    const check = [_][*:0]const u8{ "telar", "config", "check", "config.lua", "--profile", "remote" };
    const parsed_check = try Cli.parse(&check, .empty);
    try std.testing.expectEqualStrings("config.lua", std.mem.span(parsed_check.config_check.path.?));
    try std.testing.expectEqualStrings("remote", std.mem.span(parsed_check.config_check.profile.?));
}

test "CLI keeps plugin inspection installation and trust separate" {
    const install = [_][*:0]const u8{ "telar", "plugin", "install", "./plugin" };
    const parsed_install = try Cli.parse(&install, .empty);
    try std.testing.expectEqual(PluginCommand.install, parsed_install.plugin.command);

    const trust = [_][*:0]const u8{
        "telar",
        "plugin",
        "trust",
        "./plugin",
        "--capability",
        "history.read",
    };
    const parsed_trust = try Cli.parse(&trust, .empty);
    try std.testing.expectEqual(PluginCommand.trust, parsed_trust.plugin.command);
    try std.testing.expectEqual(core.plugin.Capability.history_read, parsed_trust.plugin.capabilities[0]);
}

test "CLI recognizes the runtime server" {
    const args = [_][*:0]const u8{ "telar", "server" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.run, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "CLI recognizes runtime stop" {
    const args = [_][*:0]const u8{ "telar", "server", "stop" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.stop, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "runtime stop cannot use an internal launcher mode" {
    const args = [_][*:0]const u8{ "telar", "server", "stop", "--background" };
    try std.testing.expectError(error.ConflictingServerAction, Cli.parse(&args, .empty));
}

test "server socket and launcher mode are explicit" {
    const args = [_][*:0]const u8{
        "telar",
        "server",
        "--background",
        "--socket",
        "/tmp/telar-test.sock",
    };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(ServerMode.background_launcher, cli.server.mode);
    try std.testing.expectEqualStrings(
        "/tmp/telar-test.sock",
        std.mem.span(cli.server.socket.?),
    );
}

test "server graphics memory quotas are configurable and bounded" {
    const args = [_][*:0]const u8{
        "telar",
        "server",
        "--graphics-pane-mib",
        "32",
        "--graphics-global-mib",
        "128",
    };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(@as(usize, 32 * 1024 * 1024), cli.server.graphics.pane_bytes);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), cli.server.graphics.global_bytes);

    const invalid = [_][*:0]const u8{
        "telar",
        "server",
        "--graphics-pane-mib",
        "65",
    };
    try std.testing.expectError(error.InvalidGraphicsLimits, Cli.parse(&invalid, .empty));
}

test "CLI parses history search filters" {
    const args = [_][*:0]const u8{
        "telar",
        "history",
        "search",
        "git commit",
        "--workspace",
        "/work/telar",
        "--failed",
        "--limit",
        "40",
    };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .history);
    try std.testing.expectEqual(HistoryAction.search, cli.history.action);
    try std.testing.expectEqualStrings("git commit", std.mem.span(cli.history.query.?));
    try std.testing.expectEqual(core.schema.HistoryScope.workspace, cli.history.scope);
    try std.testing.expectEqualStrings("/work/telar", std.mem.span(cli.history.scope_value.?));
    try std.testing.expect(cli.history.failed_only);
    try std.testing.expectEqual(@as(u16, 40), cli.history.limit);
}

test "CLI rejects conflicting history scopes" {
    const args = [_][*:0]const u8{
        "telar",
        "history",
        "list",
        "--cwd",
        "--pane",
        "1",
    };
    try std.testing.expectError(error.ConflictingHistoryScopes, Cli.parse(&args, .empty));
}

test "the runtime directory must belong to the current user" {
    // Regression test for the new check: an attacker-owned directory on the
    // socket path is rejected explicitly rather than via a later EPERM.
    try checkRuntimeDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkRuntimeDirectoryOwner(0, 1000));
}

test "history fields escape terminal control bytes" {
    var storage: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    try writeHistoryField(&writer, "echo\n\x1b[31m");
    try std.testing.expectEqualStrings("echo\\n\\x1b[31m", writer.buffered());
}
