//! Composition of the long-lived runtime process selected by `telar server`.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const config = @import("config.zig");
const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");
const plugin_cli = @import("plugin.zig");
const proxy_cli = @import("proxy.zig");

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
    if (options.action == .endpoint) {
        return printEndpoint(init, &connector);
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

/// Ensures the runtime is running and prints its socket path on one line.
/// `telar --remote` runs this over SSH to discover the remote endpoint.
fn printEndpoint(init: std.process.Init, connector: *const RuntimeConnector) !void {
    var connection = try connector.connectOrStart(.{});
    connection.deinit(init.io);

    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}\n", .{connector.endpointPath()});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}

const Launch = struct {
    process: std.process.Init,
    options: ServerOptions,
    connector: RuntimeConnector,
    config_generation: ?*frontend.config.Generation = null,
    config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    configured_history_buffer: [std.fs.max_path_bytes]u8 = undefined,
    configured_history_path: ?[:0]const u8 = null,
    configured_proxy_directory: ?[]u8 = null,
    proxy_intercept_host_storage: [frontend.config.max_proxy_intercept_hosts][]const u8 = undefined,
    proxy_intercept_hosts: []const []const u8 = &.{},
    description_arguments: [frontend.config.max_agent_description_command_args][]const u8 = undefined,
    agent_description_options: ?backend.runtime.AgentDescriptionOptions = null,
    engine_arguments: [frontend.config.max_agent_description_command_args][]const u8 = undefined,
    engine_options: ?backend.runtime.EngineOptions = null,
    agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
    history_filters: core.history_filter.Filters = .{},
    history_output_capture: bool = false,
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
    proxy_system_trusted: bool = false,
    proxy_capture: backend.proxy.CaptureConfig = .{},
    tap_specs: [backend.plugins.max_workers]backend.plugins.Spec = undefined,
    tap_spec_count: u8 = 0,
    tap_snapshot_buffer: [std.fs.max_path_bytes]u8 = undefined,
    tap_snapshot_directory: ?[]const u8 = null,
    trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

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
            if (launch.options.fresh) {
                if (launch.session_path) |path| {
                    _ = try setSessionAside(launch.process.io, path);
                }
            }
            if (launch.config_generation) |generation| {
                try launch.prepareTapPlugins(generation);
            }
        }
    }

    fn applyConfig(launch: *Launch, generation: *frontend.config.Generation) !void {
        const runtime_config = &generation.snapshot.runtime;
        launch.agent_manifests = runtime_config.agent_manifests;
        launch.history_filters = runtime_config.history_filters;
        launch.history_output_capture = runtime_config.history_output_capture;
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

        launch.proxy_intercept_hosts = runtime_config.proxyInterceptHosts(&launch.proxy_intercept_host_storage);
        launch.proxy_capture = .{
            .enabled = runtime_config.proxy_capture_enabled,
            .max_part_bytes = runtime_config.proxy_capture_max_part_bytes,
            .max_exchange_bytes = runtime_config.proxy_capture_max_exchange_bytes,
            .max_total_bytes = runtime_config.proxy_capture_max_total_bytes,
            .join_timeout_ms = runtime_config.proxy_capture_join_timeout_ms,
        };
        if (runtime_config.proxyCaDir()) |ca_directory| {
            launch.configured_proxy_directory = try resolveConfigPath(
                launch.process.gpa,
                generation.configDir(),
                ca_directory,
            );
        }
        if (runtime_config.agent_descriptions.enabled()) {
            launch.agent_description_options = .{
                .arguments = runtime_config.agent_descriptions.arguments(&launch.description_arguments),
                .timeout_ms = runtime_config.agent_descriptions.timeout_ms,
            };
        }
        if (runtime_config.engine.enabled()) {
            launch.engine_options = .{
                .arguments = runtime_config.engine.arguments(&launch.engine_arguments),
                .timeout_ms = runtime_config.engine.timeout_ms,
                .idle_timeout_ms = runtime_config.engine_idle_timeout_ms,
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
        const proxy_directory = launch.configured_proxy_directory orelse block: {
            const resolved = try resolveProxyDirectory(launch.process.minimal.environ, &launch.default_proxy_buffer);
            launch.default_proxy_directory = try launch.process.gpa.dupe(u8, resolved);
            break :block launch.default_proxy_directory.?;
        };
        _ = try proxy_cli.rotateIfNeeded(launch.process, proxy_directory);
        launch.proxy_system_trusted = proxy_cli.trusted(launch.process, proxy_directory);
        if (proxy_enabled) {
            const authority_names = proxyAuthorityNames(launch.proxy_system_trusted);
            try prepareProxyDirectory(launch.process.io, proxy_directory);
            launch.proxy_options = .{
                .key_path = try std.fmt.bufPrint(&launch.proxy_key_buffer, "{s}/{s}", .{ proxy_directory, authority_names.key }),
                .certificate_path = try std.fmt.bufPrint(&launch.proxy_cert_buffer, "{s}/{s}", .{ proxy_directory, authority_names.certificate }),
                .bundle_path = try std.fmt.bufPrint(&launch.proxy_bundle_buffer, "{s}/ca-bundle.pem", .{proxy_directory}),
                .system_authority = launch.proxy_system_trusted,
                .intercept_hosts = launch.proxy_intercept_hosts,
                .capture = launch.proxy_capture,
            };
        }
    }

    fn prepareTapPlugins(launch: *Launch, generation: *frontend.config.Generation) !void {
        const trust_path = try plugin_cli.trustPath(launch.process.minimal.environ, &launch.trust_path_buffer);
        const trust = try plugin_cli.loadTrustStore(launch.process, trust_path);
        const registry = try frontend.plugins.Registry.loadWithTrust(
            launch.process.gpa,
            launch.process.io,
            generation.configDir(),
            generation.pluginSlice(),
            &trust,
        );

        for (registry.packages[0..registry.count]) |*package| {
            if (!package.manifest.capabilities.contains(.proxy_tap)) continue;
            const granted = grantedCapabilities(&trust, package);
            if (!granted.contains(.proxy_tap)) continue;
            if (launch.tap_spec_count == backend.plugins.max_workers) return error.TooManyTapPlugins;
            const snapshot_root = try launch.ensureTapSnapshot();
            var package_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const package_path = try std.fmt.bufPrint(&package_buffer, "{s}/package-{d}", .{ snapshot_root, launch.tap_spec_count });
            try frontend.plugins.installPackage(launch.process.gpa, launch.process.io, package, package_path);
            const copied = try frontend.plugins.inspectPackage(launch.process.gpa, launch.process.io, package_path);
            if (!std.mem.eql(u8, &copied.digest, &package.digest)) return error.PluginChangedDuringInstall;
            var entry_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const entry = try std.fmt.bufPrint(&entry_buffer, "{s}/{s}", .{ package_path, copied.manifest.entry() });
            launch.tap_specs[launch.tap_spec_count] = try backend.plugins.Spec.init(launch.tap_spec_count, generation.number, .{
                .id = copied.manifest.id(),
                .entry = entry,
                .digest = copied.digest,
                .declared = copied.manifest.capabilities,
                .granted = granted,
            });
            launch.tap_spec_count += 1;
        }
    }

    fn ensureTapSnapshot(launch: *Launch) ![]const u8 {
        if (launch.tap_snapshot_directory) |path| return path;
        var nonce: [16]u8 = undefined;
        try launch.process.io.randomSecure(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const path = try std.fmt.bufPrint(&launch.tap_snapshot_buffer, "/tmp/telar-tap-workers-{d}-{s}", .{ std.c.getuid(), &nonce_hex });
        try Io.Dir.cwd().createDir(launch.process.io, path, File.Permissions.fromMode(0o700));
        launch.tap_snapshot_directory = path;
        return path;
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
                .history_filters = launch.history_filters,
                .history_output_capture = launch.history_output_capture,
                .proxy = launch.proxy_options,
                .proxy_system_trusted = launch.proxy_system_trusted,
                .plugins = launch.tap_specs[0..launch.tap_spec_count],
                .agent_descriptions = launch.agent_description_options,
                .engine = launch.engine_options,
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
        var argv: [14][]const u8 = undefined;
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
        if (launch.options.fresh) {
            argv[argc] = "--fresh";
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
        if (launch.tap_snapshot_directory) |directory| {
            Io.Dir.cwd().deleteTree(launch.process.io, directory) catch {};
            launch.tap_snapshot_directory = null;
        }
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

fn grantedCapabilities(trust: *const core.plugin.TrustStore, package: *const frontend.plugins.Package) core.plugin.CapabilitySet {
    var granted = core.plugin.CapabilitySet.initEmpty();
    for (trust.entries[0..trust.count]) |entry| {
        if (entry.grant.plugin_hash != core.plugin.stableId(package.manifest.id())) continue;
        if (!std.mem.eql(u8, &entry.grant.digest, &package.digest)) continue;
        granted.setUnion(entry.grant.capabilities);
    }
    return granted;
}

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

/// Renames the session checkpoint at `path` to `<path>.previous` so a fresh
/// runtime starts empty without destroying the session it replaces. The
/// runtime persists to `path` again, so the previous session survives exactly
/// one fresh start. Returns false when there was nothing to set aside.
///
/// ```zig
/// const kept = try setSessionAside(io, "/home/me/.local/share/telar/session.ckpt");
/// ```
pub fn setSessionAside(io: Io, path: []const u8) !bool {
    var previous_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const previous = try std.fmt.bufPrint(&previous_buffer, "{s}.previous", .{path});
    Io.Dir.renameAbsolute(path, previous, io) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
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

const ProxyAuthorityNames = struct {
    key: []const u8,
    certificate: []const u8,
};

fn proxyAuthorityNames(system_trusted: bool) ProxyAuthorityNames {
    if (system_trusted) {
        return .{ .key = "ca-system-key.pem", .certificate = "ca-system-cert.pem" };
    }

    return .{ .key = "ca-key.pem", .certificate = "ca-cert.pem" };
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

test "runtime selects the installed system authority without reusing the private CA" {
    const private = proxyAuthorityNames(false);
    const system = proxyAuthorityNames(true);

    try std.testing.expectEqualStrings("ca-key.pem", private.key);
    try std.testing.expectEqualStrings("ca-cert.pem", private.certificate);
    try std.testing.expectEqualStrings("ca-system-key.pem", system.key);
    try std.testing.expectEqualStrings("ca-system-cert.pem", system.certificate);
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

test "a fresh start sets the previous session aside once" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryDirectory(&temp, &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/session.ckpt", .{root});
    var previous_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const previous = try std.fmt.bufPrint(&previous_buffer, "{s}/session.ckpt.previous", .{root});
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "session.ckpt", .data = "session" });

    try std.testing.expect(try setSessionAside(std.testing.io, path));

    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false }));
    const moved = try Io.Dir.cwd().readFileAlloc(std.testing.io, previous, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("session", moved);
    try std.testing.expect(!try setSessionAside(std.testing.io, path));
}

test "runtime storage rejects directories owned by another user" {
    try checkDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkDirectoryOwner(0, 1000));
}
