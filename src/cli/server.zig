//! Composition of the long-lived runtime process selected by `telar server`.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const config = @import("config.zig");
const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

const Io = std.Io;
const File = Io.File;
const RuntimeConnector = runtime_connection.RuntimeConnector;
const ServerOptions = parser.ServerOptions;

/// Executes the selected server action. A running action prepares persistent
/// paths, initializes one public Runtime with production dependencies and owns
/// its complete `init`, `run`, `deinit` lifecycle.
///
/// ```zig
/// try server.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: ServerOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
    if (options.action == .stop) {
        return stop(init, &connector);
    }

    var launch: Launch = undefined;
    try launch.prepare(.{
        .process = init,
        .options = options,
        .connector = connector,
    });
    defer launch.deinit();

    if (launch.options.mode == .background_launcher) {
        return launch.launchDaemon();
    }

    var runtime: backend.runtime.Runtime = undefined;
    try runtime.init(launch.runtimeInitialization());
    defer runtime.deinit();

    try runtime.run();
}

const Preparation = struct {
    process: std.process.Init,
    options: ServerOptions,
    connector: RuntimeConnector,
};

const HistoryPath = struct {
    path: [:0]const u8,
    managed_directory: ?[]const u8,
};

const Launch = struct {
    process: std.process.Init,
    options: ServerOptions,
    connector: RuntimeConnector,
    config_generation: ?*frontend.config.Generation = null,
    config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    configured_history_buffer: [std.fs.max_path_bytes]u8 = undefined,
    configured_history_path: ?[:0]const u8 = null,
    configured_proxy_directory: ?[]u8 = null,
    proxy_passthrough_host_storage: [frontend.config.max_proxy_passthrough_hosts][]const u8 = undefined,
    proxy_passthrough_hosts: []const []const u8 = &.{},
    description_arguments: [frontend.config.max_agent_description_command_args][]const u8 = undefined,
    agent_description_options: ?backend.runtime.AgentDescriptionOptions = null,
    agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
    session_persist: bool = true,
    session_resume_agents: bool = true,
    configured_session_buffer: [std.fs.max_path_bytes]u8 = undefined,
    configured_session_path: ?[]const u8 = null,
    session_buffer: [std.fs.max_path_bytes]u8 = undefined,
    session_path: ?[]const u8 = null,
    history_buffer: [std.fs.max_path_bytes]u8 = undefined,
    history_path: HistoryPath = undefined,
    default_proxy_buffer: [std.fs.max_path_bytes]u8 = undefined,
    default_proxy_directory: ?[]u8 = null,
    proxy_key_buffer: [std.fs.max_path_bytes]u8 = undefined,
    proxy_cert_buffer: [std.fs.max_path_bytes]u8 = undefined,
    proxy_bundle_buffer: [std.fs.max_path_bytes]u8 = undefined,
    proxy_options: ?backend.runtime.ProxyOptions = null,

    fn prepare(launch: *Launch, preparation: Preparation) !void {
        launch.* = .{
            .process = preparation.process,
            .options = preparation.options,
            .connector = preparation.connector,
        };
        errdefer launch.deinit();

        launch.config_generation = try config.loadGeneration(preparation.process, .{
            .path = preparation.options.config,
            .disabled = preparation.options.no_config,
            .profile = preparation.options.profile,
        }, &launch.config_path_buffer);
        if (launch.config_generation) |generation| {
            try launch.applyConfig(generation);
        }
        try launch.options.graphics.validate();

        if (launch.options.mode != .background_launcher) {
            try launch.prepareRuntimeStorage();
        }
    }

    fn applyConfig(launch: *Launch, generation: *frontend.config.Generation) !void {
        const runtime_config = &generation.snapshot.runtime;
        launch.agent_manifests = runtime_config.agent_manifests;
        launch.session_persist = runtime_config.session_persist;
        launch.session_resume_agents = runtime_config.session_resume_agents;
        if (runtime_config.sessionPath()) |session_path| {
            const resolved = try resolveConfigPath(launch.process.gpa, generation.configDir(), session_path);
            defer launch.process.gpa.free(resolved);
            launch.configured_session_path = try std.fmt.bufPrint(&launch.configured_session_buffer, "{s}", .{resolved});
        }
        if (!launch.options.graphics_pane_set) {
            launch.options.graphics.pane_bytes = runtime_config.graphics_pane_bytes;
        }
        if (!launch.options.graphics_global_set) {
            launch.options.graphics.global_bytes = runtime_config.graphics_global_bytes;
        }
        if (runtime_config.historyPath()) |history_path| {
            const resolved = try resolveConfigPath(launch.process.gpa, generation.configDir(), history_path);
            defer launch.process.gpa.free(resolved);
            launch.configured_history_path = try std.fmt.bufPrintZ(&launch.configured_history_buffer, "{s}", .{resolved});
        }

        launch.proxy_passthrough_hosts = runtime_config.proxyPassthroughHosts(&launch.proxy_passthrough_host_storage);
        if (runtime_config.proxy_enabled) {
            if (runtime_config.proxyCaDir()) |ca_directory| {
                launch.configured_proxy_directory = try resolveConfigPath(
                    launch.process.gpa,
                    generation.configDir(),
                    ca_directory,
                );
            }
        }
        if (runtime_config.agent_descriptions.enabled()) {
            launch.agent_description_options = .{
                .arguments = runtime_config.agent_descriptions.arguments(&launch.description_arguments),
                .timeout_ms = runtime_config.agent_descriptions.timeout_ms,
            };
        }
    }

    fn prepareRuntimeStorage(launch: *Launch) !void {
        try launch.connector.prepareServerDirectory();
        launch.history_path = if (launch.configured_history_path) |path|
            .{ .path = path, .managed_directory = null }
        else
            try resolveHistoryPath(launch.process.minimal.environ, &launch.history_buffer);
        try prepareHistoryDatabase(launch.process.io, launch.history_path);
        if (launch.session_persist) {
            launch.session_path = launch.configured_session_path orelse try std.fmt.bufPrint(
                &launch.session_buffer,
                "{s}/session.ckpt",
                .{std.fs.path.dirname(launch.history_path.path) orelse "."},
            );
        }

        const proxy_enabled = if (launch.config_generation) |generation|
            generation.snapshot.runtime.proxy_enabled
        else
            false;
        const proxy_directory: ?[]const u8 = if (proxy_enabled)
            launch.configured_proxy_directory orelse block: {
                const resolved = try resolveProxyDirectory(launch.process.minimal.environ, &launch.default_proxy_buffer);
                launch.default_proxy_directory = try launch.process.gpa.dupe(u8, resolved);
                break :block launch.default_proxy_directory.?;
            }
        else
            null;
        if (proxy_directory) |directory| {
            try prepareProxyDirectory(launch.process.io, directory);
            launch.proxy_options = .{
                .key_path = try std.fmt.bufPrint(&launch.proxy_key_buffer, "{s}/ca-key.pem", .{directory}),
                .certificate_path = try std.fmt.bufPrint(&launch.proxy_cert_buffer, "{s}/ca-cert.pem", .{directory}),
                .bundle_path = try std.fmt.bufPrint(&launch.proxy_bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
                .passthrough_hosts = launch.proxy_passthrough_hosts,
            };
        }
    }

    fn runtimeInitialization(launch: *const Launch) backend.runtime.Initialization {
        return .{
            .dependencies = .{
                .io = launch.process.io,
                .allocator = launch.process.gpa,
            },
            .options = .{
                .endpoint = launch.connector.endpointPath(),
                .graphics = launch.options.graphics,
                .environment = launch.process.minimal.environ,
                .history_path = launch.history_path.path,
                .proxy = launch.proxy_options,
                .agent_descriptions = launch.agent_description_options,
                .agent_manifests = launch.agent_manifests,
                .session_path = launch.session_path,
                .resume_agents = launch.session_resume_agents,
            },
        };
    }

    fn launchDaemon(launch: *const Launch) !void {
        if (std.c.setsid() < 0) {
            return error.DetachFailed;
        }

        var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const executable = executable_buffer[0..try std.process.executablePath(launch.process.io, &executable_buffer)];
        var pane_mib_buffer: [32]u8 = undefined;
        const pane_mib = try std.fmt.bufPrint(&pane_mib_buffer, "{d}", .{launch.options.graphics.pane_bytes / (1024 * 1024)});
        var global_mib_buffer: [32]u8 = undefined;
        const global_mib = try std.fmt.bufPrint(&global_mib_buffer, "{d}", .{launch.options.graphics.global_bytes / (1024 * 1024)});
        var argv: [13][]const u8 = undefined;
        var argc: usize = 0;
        for ([_][]const u8{
            executable,
            "server",
            "--daemonized",
            "--socket",
            launch.connector.endpointPath(),
            "--graphics-pane-mib",
            pane_mib,
            "--graphics-global-mib",
            global_mib,
        }) |arg| {
            argv[argc] = arg;
            argc += 1;
        }
        if (launch.options.config) |path| {
            argv[argc] = "--config";
            argv[argc + 1] = std.mem.span(path);
            argc += 2;
        } else if (launch.options.no_config) {
            argv[argc] = "--no-config";
            argc += 1;
        }
        if (launch.options.profile) |profile| {
            argv[argc] = "--profile";
            argv[argc + 1] = std.mem.span(profile);
            argc += 2;
        }

        const daemon = try std.process.spawn(launch.process.io, .{
            .argv = argv[0..argc],
            .cwd = .{ .path = "/" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = daemon;
    }

    fn deinit(launch: *Launch) void {
        if (launch.default_proxy_directory) |directory| {
            launch.process.gpa.free(directory);
            launch.default_proxy_directory = null;
        }
        if (launch.configured_proxy_directory) |directory| {
            launch.process.gpa.free(directory);
            launch.configured_proxy_directory = null;
        }
        if (launch.config_generation) |generation| {
            generation.deinit();
            launch.config_generation = null;
        }
    }
};

fn stop(init: std.process.Init, connector: *const RuntimeConnector) !void {
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

fn resolveConfigPath(gpa: std.mem.Allocator, config_directory: []const u8, configured_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(configured_path)) {
        return gpa.dupe(u8, configured_path);
    }

    return std.fs.path.resolve(gpa, &.{ config_directory, configured_path });
}

fn resolveProxyDirectory(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/proxy", .{base});
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/proxy", .{home});
}

fn prepareProxyDirectory(io: Io, directory: []const u8) !void {
    const permissions = File.Permissions.fromMode(0o700);
    _ = try Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) {
        return error.InvalidProxyDirectory;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch return error.NameTooLong;
    var native_stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &native_stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return error.InvalidProxyDirectory;
    }
    try checkDirectoryOwner(native_stat.uid, std.c.getuid());
    try Io.Dir.cwd().setFilePermissions(io, directory, permissions, .{ .follow_symlinks = false });
}

fn resolveHistoryPath(environ: std.process.Environ, buffer: []u8) !HistoryPath {
    if (environ.getPosix("TELAR_HISTORY")) |path| {
        if (path.len != 0) {
            return .{
                .path = try std.fmt.bufPrintZ(buffer, "{s}", .{path}),
                .managed_directory = null,
            };
        }
    }

    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) {
            const directory = try std.fmt.bufPrint(buffer, "{s}/telar", .{base});
            const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
            return .{
                .path = buffer[0 .. directory.len + path.len :0],
                .managed_directory = directory,
            };
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }
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
        try Io.Dir.cwd().setFilePermissions(io, directory, permissions, .{ .follow_symlinks = false });
    }

    const file = try Io.Dir.createFileAbsolute(io, history_path.path, .{
        .read = true,
        .truncate = false,
        .permissions = File.Permissions.fromMode(0o600),
    });
    file.close(io);
    try Io.Dir.cwd().setFilePermissions(io, history_path.path, File.Permissions.fromMode(0o600), .{ .follow_symlinks = false });
}

fn checkDirectoryOwner(owner: std.c.uid_t, current_user: std.c.uid_t) error{WrongOwner}!void {
    if (owner != current_user) {
        return error.WrongOwner;
    }
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

fn temporaryDirectory(temp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try temp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "explicit history storage overrides XDG data storage" {
    var environment = try testEnvironment(&.{
        .{ "TELAR_HISTORY", "/var/lib/telar/history.db" },
        .{ "XDG_DATA_HOME", "/data" },
    });
    defer environment.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const history = try resolveHistoryPath(.{ .block = environment.block }, &buffer);

    try std.testing.expectEqualStrings("/var/lib/telar/history.db", history.path);
    try std.testing.expect(history.managed_directory == null);
}

test "history and proxy storage prefer XDG data home" {
    var environment = try testEnvironment(&.{
        .{ "XDG_DATA_HOME", "/data" },
        .{ "HOME", "/home/adrian" },
    });
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var proxy_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const history = try resolveHistoryPath(environ, &history_buffer);

    try std.testing.expectEqualStrings("/data/telar", history.managed_directory.?);
    try std.testing.expectEqualStrings("/data/telar/history.db", history.path);
    try std.testing.expectEqualStrings("/data/telar/proxy", try resolveProxyDirectory(environ, &proxy_buffer));
}

test "relative configured paths resolve from the config directory" {
    const relative = try resolveConfigPath(std.testing.allocator, "/config/telar", "state/history.db");
    defer std.testing.allocator.free(relative);
    const absolute = try resolveConfigPath(std.testing.allocator, "/ignored", "/state/proxy");
    defer std.testing.allocator.free(absolute);

    try std.testing.expectEqualStrings("/config/telar/state/history.db", relative);
    try std.testing.expectEqualStrings("/state/proxy", absolute);
}

test "runtime storage creates private history and proxy paths" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryDirectory(&temp, &root_buffer);
    var history_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_directory = try std.fmt.bufPrint(&history_directory_buffer, "{s}/state", .{root});
    var history_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_path = try std.fmt.bufPrintZ(&history_path_buffer, "{s}/history.db", .{history_directory});
    var proxy_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const proxy_directory = try std.fmt.bufPrint(&proxy_directory_buffer, "{s}/proxy", .{root});

    try prepareHistoryDatabase(std.testing.io, .{
        .path = history_path,
        .managed_directory = history_directory,
    });
    try prepareProxyDirectory(std.testing.io, proxy_directory);

    const history_directory_stat = try Io.Dir.cwd().statFile(std.testing.io, history_directory, .{ .follow_symlinks = false });
    const history_stat = try Io.Dir.cwd().statFile(std.testing.io, history_path, .{ .follow_symlinks = false });
    const proxy_stat = try Io.Dir.cwd().statFile(std.testing.io, proxy_directory, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), history_directory_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), history_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o700), proxy_stat.permissions.toMode() & 0o777);
}

test "runtime storage rejects directories owned by another user" {
    try checkDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkDirectoryOwner(0, 1000));
}
