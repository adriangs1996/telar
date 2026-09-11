const std = @import("std");
const ServerOptionsType = @import("arguments/ServerOptions.zig");
const RuntimeConnectorType = @import("RuntimeConnector.zig");
const GenerationType = @import("telar-frontend").Generation;
const max_intercept_hosts = @import("telar-core").max_intercept_hosts;
const max_agent_description_command_args_module = @import("telar-frontend").max_agent_description_command_args;
const AgentDescriptionOptionsType = @import("telar-backend").AgentDescriptionOptions;
const Options = @import("telar-backend").Options;
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const FiltersType = @import("telar-core").Filters;
const HistoryPath = @import("HistoryPath.zig");
const Config = @import("telar-backend").Config;
const ConfigType = @import("telar-backend").ProxyCaptureConfig;
const max_workers_module = @import("telar-backend").max_workers;
const ServiceSpec = @import("telar-backend").ServiceSpec;
const ServerPreparation = @import("ServerPreparation.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const proxy_cli = @import("proxy.zig");
const plugin_cli = @import("plugin.zig");
const RegistryType = @import("telar-frontend").Registry;
const installPackage_module = @import("telar-frontend").installPackage;
const inspectPackage_module = @import("telar-frontend").inspectPackage;
const InitializationType = @import("telar-backend").Initialization;
const Launch = @This();

process: std.process.Init,
options: ServerOptionsType,
connector: RuntimeConnectorType,
config_generation: ?*GenerationType = null,
config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
configured_history_buffer: [std.fs.max_path_bytes]u8 = undefined,
configured_history_path: ?[:0]const u8 = null,
configured_proxy_directory: ?[]u8 = null,
proxy_intercept_host_storage: [max_intercept_hosts][]const u8 = undefined,
proxy_intercept_hosts: []const []const u8 = &.{},
description_arguments: [max_agent_description_command_args_module][]const u8 = undefined,
agent_description_options: ?AgentDescriptionOptionsType = null,
engine_arguments: [max_agent_description_command_args_module][]const u8 = undefined,
engine_options: ?Options = null,
agent_manifests: TableType = builtin_table_module,
history_filters: FiltersType = .{},
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
proxy_options: ?Config = null,
proxy_system_trusted: bool = false,
proxy_capture: ConfigType = .{},
tap_specs: [max_workers_module]ServiceSpec = undefined,
tap_spec_count: u8 = 0,
tap_snapshot_buffer: [std.fs.max_path_bytes]u8 = undefined,
tap_snapshot_directory: ?[]const u8 = null,
trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

pub fn prepare(launch: *Launch, preparation: ServerPreparation) !void {
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
                _ = try server.setSessionAside(launch.process.io, path);
            }
        }
        if (launch.config_generation) |generation| {
            try launch.prepareTapPlugins(generation);
        }
    }
}

fn applyConfig(launch: *Launch, generation: *GenerationType) !void {
    const runtime_config = &generation.snapshot.runtime;
    launch.agent_manifests = runtime_config.agent_manifests;
    launch.history_filters = runtime_config.history_filters;
    launch.history_output_capture = runtime_config.history_output_capture;
    launch.session_persist = runtime_config.session_persist;
    launch.session_resume_agents = runtime_config.session_resume_agents;
    if (runtime_config.sessionPath()) |session_path| {
        const resolved = try server.resolveConfigPath(launch.process.gpa, generation.configDir(), session_path);
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
        const resolved = try server.resolveConfigPath(launch.process.gpa, generation.configDir(), history_path);
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
        launch.configured_proxy_directory = try server.resolveConfigPath(
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
        try server.resolveHistoryPath(launch.process.minimal.environ, &launch.history_buffer);
    try server.prepareHistoryDatabase(launch.process.io, launch.history_path);
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
        const resolved = try server.resolveProxyDirectory(launch.process.minimal.environ, &launch.default_proxy_buffer);
        launch.default_proxy_directory = try launch.process.gpa.dupe(u8, resolved);
        break :block launch.default_proxy_directory.?;
    };
    _ = try proxy_cli.rotateIfNeeded(launch.process, proxy_directory);
    launch.proxy_system_trusted = proxy_cli.trusted(launch.process, proxy_directory);
    if (proxy_enabled) {
        const authority_names = server.proxyAuthorityNames(launch.proxy_system_trusted);
        try server.prepareProxyDirectory(launch.process.io, proxy_directory);
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

fn prepareTapPlugins(launch: *Launch, generation: *GenerationType) !void {
    const trust_path = try plugin_cli.trustPath(launch.process.minimal.environ, &launch.trust_path_buffer);
    const trust = try plugin_cli.loadTrustStore(launch.process, trust_path);
    const registry = try RegistryType.loadWithTrust(
        .{
            .gpa = launch.process.gpa,
            .io = launch.process.io,
            .config_dir = generation.configDir(),
        },
        generation.pluginSlice(),
        &trust,
    );

    for (registry.packages[0..registry.count]) |*package| {
        if (!package.manifest.capabilities.contains(.proxy_tap)) {
            continue;
        }
        const granted = server.grantedCapabilities(&trust, package);
        if (!granted.contains(.proxy_tap)) {
            continue;
        }
        if (launch.tap_spec_count == max_workers_module) {
            return error.TooManyTapPlugins;
        }
        const snapshot_root = try launch.ensureTapSnapshot();
        var package_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const package_path = try std.fmt.bufPrint(&package_buffer, "{s}/package-{d}", .{ snapshot_root, launch.tap_spec_count });
        try installPackage_module(launch.process.gpa, launch.process.io, .{
            .package = package,
            .destination = package_path,
        });
        const copied = try inspectPackage_module(launch.process.gpa, launch.process.io, package_path);
        if (!std.mem.eql(u8, &copied.digest, &package.digest)) {
            return error.PluginChangedDuringInstall;
        }
        var entry_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const entry = try std.fmt.bufPrint(&entry_buffer, "{s}/{s}", .{ package_path, copied.manifest.entry() });
        launch.tap_specs[launch.tap_spec_count] = try ServiceSpec.init(launch.tap_spec_count, generation.number, .{
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
    if (launch.tap_snapshot_directory) |path| {
        return path;
    }
    var nonce: [16]u8 = undefined;
    try launch.process.io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const path = try std.fmt.bufPrint(&launch.tap_snapshot_buffer, "/tmp/telar-tap-workers-{d}-{s}", .{ std.c.getuid(), &nonce_hex });
    try std.Io.Dir.cwd().createDir(launch.process.io, path, std.Io.File.Permissions.fromMode(0o700));
    launch.tap_snapshot_directory = path;
    return path;
}

pub fn runtimeInitialization(launch: *const Launch) InitializationType {
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

pub fn launchDaemon(launch: *const Launch) !void {
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

pub fn deinit(launch: *Launch) void {
    if (launch.tap_snapshot_directory) |directory| {
        std.Io.Dir.cwd().deleteTree(launch.process.io, directory) catch {};
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
