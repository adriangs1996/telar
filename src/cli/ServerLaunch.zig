const pi_rpc = @import("pi_rpc");
const exchangecapture = @import("exchangecapture");
const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const backend = @import("telar-backend");
const std = @import("std");
const ServerOptions = @import("arguments/ServerOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const HistoryPath = @import("HistoryPath.zig");
const ServerPreparation = @import("ServerPreparation.zig");
const config = @import("config.zig");
const server = @import("server.zig");
const proxy_cli = @import("proxy.zig");
const plugin_cli = @import("plugin.zig");
const Launch = @This();

process: std.process.Init,
options: ServerOptions,
connector: RuntimeConnector,
config_generation: ?*client.Generation = null,
config_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
configured_history_buffer: [std.fs.max_path_bytes]u8 = undefined,
configured_history_path: ?[:0]const u8 = null,
configured_proxy_directory: ?[]u8 = null,
proxy_intercept_host_storage: [core.max_intercept_hosts][]const u8 = undefined,
proxy_intercept_hosts: []const []const u8 = &.{},
description_arguments: [data.config_values.max_agent_description_command_args][]const u8 = undefined,
agent_description_options: ?backend.AgentDescriptionOptions = null,
engine_arguments: [data.config_values.max_agent_description_command_args][]const u8 = undefined,
engine_options: ?pi_rpc.Options = null,
agent_manifests: core.Table = core.builtin_table,
history_filters: core.Filters = .{},
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
proxy_secret_buffer: [std.fs.max_path_bytes]u8 = undefined,
proxy_port_buffer: [std.fs.max_path_bytes]u8 = undefined,
proxy_legacy_port_buffer: [std.fs.max_path_bytes]u8 = undefined,
proxy_options: ?backend.Config = null,
proxy_system_trusted: bool = false,
proxy_capture: exchangecapture.Config = .{},
tap_specs: [backend.max_workers]backend.ServiceSpec = undefined,
tap_spec_count: u8 = 0,
tap_snapshot_buffer: [std.fs.max_path_bytes]u8 = undefined,
tap_snapshot_directory: ?[]const u8 = null,
trust_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

pub fn prepare(self: *Launch, preparation: ServerPreparation) !void {
    self.* = .{
        .process = preparation.process,
        .options = preparation.options,
        .connector = preparation.connector,
    };
    errdefer self.deinit();

    self.config_generation = try config.loadGeneration(preparation.process, .{
        .path = preparation.options.config,
        .disabled = preparation.options.no_config,
        .profile = preparation.options.profile,
    }, &self.config_path_buffer);
    if (self.config_generation) |generation| {
        try self.applyConfig(generation);
    }
    try self.options.graphics.validate();

    if (self.options.mode != .background_launcher) {
        try self.prepareRuntimeStorage();
        if (self.options.fresh) {
            if (self.session_path) |path| {
                _ = try server.setSessionAside(self.process.io, path);
            }
        }
        if (self.config_generation) |generation| {
            try self.prepareTapPlugins(generation);
        }
    }
}

fn applyConfig(self: *Launch, generation: *client.Generation) !void {
    const runtime_config = &generation.snapshot.runtime;
    self.agent_manifests = runtime_config.agent_manifests;
    self.history_filters = runtime_config.history_filters;
    self.history_output_capture = runtime_config.history_output_capture;
    self.session_persist = runtime_config.session_persist;
    self.session_resume_agents = runtime_config.session_resume_agents;
    if (runtime_config.sessionPath()) |session_path| {
        const resolved = try server.resolveConfigPath(self.process.gpa, generation.configDir(), session_path);
        defer self.process.gpa.free(resolved);
        self.configured_session_path = try std.fmt.bufPrint(&self.configured_session_buffer, "{s}", .{resolved});
    }
    if (!self.options.graphics_pane_set) {
        self.options.graphics.pane_bytes = runtime_config.graphics_pane_bytes;
    }
    if (!self.options.graphics_global_set) {
        self.options.graphics.global_bytes = runtime_config.graphics_global_bytes;
    }
    if (runtime_config.historyPath()) |history_path| {
        const resolved = try server.resolveConfigPath(self.process.gpa, generation.configDir(), history_path);
        defer self.process.gpa.free(resolved);
        self.configured_history_path = try std.fmt.bufPrintZ(&self.configured_history_buffer, "{s}", .{resolved});
    }

    self.proxy_intercept_hosts = runtime_config.proxyInterceptHosts(&self.proxy_intercept_host_storage);
    self.proxy_capture = .{
        .enabled = runtime_config.proxy_capture_enabled,
        .max_part_bytes = runtime_config.proxy_capture_max_part_bytes,
        .max_exchange_bytes = runtime_config.proxy_capture_max_exchange_bytes,
        .max_total_bytes = runtime_config.proxy_capture_max_total_bytes,
        .join_timeout_ms = runtime_config.proxy_capture_join_timeout_ms,
    };
    if (runtime_config.proxyCaDir()) |ca_directory| {
        self.configured_proxy_directory = try server.resolveConfigPath(
            self.process.gpa,
            generation.configDir(),
            ca_directory,
        );
    }
    if (runtime_config.agent_descriptions.enabled()) {
        self.agent_description_options = .{
            .arguments = runtime_config.agent_descriptions.arguments(&self.description_arguments),
            .timeout_ms = runtime_config.agent_descriptions.timeout_ms,
        };
    }
    if (runtime_config.engine.enabled()) {
        self.engine_options = .{
            .arguments = runtime_config.engine.arguments(&self.engine_arguments),
            .timeout_ms = runtime_config.engine.timeout_ms,
            .idle_timeout_ms = runtime_config.engine_idle_timeout_ms,
        };
    }
}

fn prepareRuntimeStorage(self: *Launch) !void {
    try self.connector.prepareServerDirectory();
    self.history_path = if (self.configured_history_path) |path|
        .{ .path = path, .managed_directory = null }
    else
        try server.resolveHistoryPath(self.process.minimal.environ, &self.history_buffer);
    try server.prepareHistoryDatabase(self.process.io, self.history_path);
    if (self.session_persist) {
        self.session_path = self.configured_session_path orelse try std.fmt.bufPrint(
            &self.session_buffer,
            "{s}/session.ckpt",
            .{std.fs.path.dirname(self.history_path.path) orelse "."},
        );
    }

    const proxy_enabled = if (self.config_generation) |generation|
        generation.snapshot.runtime.proxy_enabled
    else
        false;
    const proxy_directory = self.configured_proxy_directory orelse block: {
        const resolved = try server.resolveProxyDirectory(self.process.minimal.environ, &self.default_proxy_buffer);
        self.default_proxy_directory = try self.process.gpa.dupe(u8, resolved);
        break :block self.default_proxy_directory.?;
    };
    // Only the runtime on the default socket held the shared port of earlier
    // versions for the user; a development runtime must not inherit it.
    const endpoint = self.connector.endpointPath();
    const inherits_shared_port = if (client.runtime_connection.defaultEndpoint(self.process.minimal.environ)) |default_endpoint|
        std.mem.eql(u8, endpoint, default_endpoint.path())
    else |_|
        false;
    _ = try proxy_cli.rotateIfNeeded(self.process, proxy_directory);
    self.proxy_system_trusted = proxy_cli.trusted(self.process, proxy_directory);
    if (proxy_enabled) {
        const authority_names = server.proxyAuthorityNames(self.proxy_system_trusted);
        try server.prepareProxyDirectory(self.process.io, proxy_directory);
        self.proxy_options = .{
            .key_path = try std.fmt.bufPrint(&self.proxy_key_buffer, "{s}/{s}", .{ proxy_directory, authority_names.key }),
            .certificate_path = try std.fmt.bufPrint(&self.proxy_cert_buffer, "{s}/{s}", .{ proxy_directory, authority_names.certificate }),
            .bundle_path = try std.fmt.bufPrint(&self.proxy_bundle_buffer, "{s}/ca-bundle.pem", .{proxy_directory}),
            .secret_path = try std.fmt.bufPrint(&self.proxy_secret_buffer, "{s}/proxy-secret", .{proxy_directory}),
            .port_path = try backend.ProxyPortMemory.path(&self.proxy_port_buffer, proxy_directory, endpoint),
            .legacy_port_path = if (inherits_shared_port)
                try std.fmt.bufPrint(&self.proxy_legacy_port_buffer, "{s}/proxy-port", .{proxy_directory})
            else
                null,
            .endpoint = endpoint,
            .system_authority = self.proxy_system_trusted,
            .intercept_hosts = self.proxy_intercept_hosts,
            .capture = self.proxy_capture,
        };
    }
}

fn prepareTapPlugins(self: *Launch, generation: *client.Generation) !void {
    const trust_path = try plugin_cli.trustPath(self.process.minimal.environ, &self.trust_path_buffer);
    const trust = try plugin_cli.loadTrustStore(self.process, trust_path);
    const registry = try client.Registry.loadWithTrust(
        .{
            .gpa = self.process.gpa,
            .io = self.process.io,
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
        if (self.tap_spec_count == backend.max_workers) {
            return error.TooManyTapPlugins;
        }
        const snapshot_root = try self.ensureTapSnapshot();
        var package_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const package_path = try std.fmt.bufPrint(&package_buffer, "{s}/package-{d}", .{ snapshot_root, self.tap_spec_count });
        try client.installPackage(self.process.gpa, self.process.io, .{
            .package = package,
            .destination = package_path,
        });
        const copied = try client.inspectPackage(self.process.gpa, self.process.io, package_path);
        if (!std.mem.eql(u8, &copied.digest, &package.digest)) {
            return error.PluginChangedDuringInstall;
        }
        var entry_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const entry = try std.fmt.bufPrint(&entry_buffer, "{s}/{s}", .{ package_path, copied.manifest.entry() });
        self.tap_specs[self.tap_spec_count] = try backend.ServiceSpec.init(self.tap_spec_count, generation.number, .{
            .id = copied.manifest.id(),
            .entry = entry,
            .digest = copied.digest,
            .declared = copied.manifest.capabilities,
            .granted = granted,
        });
        self.tap_spec_count += 1;
    }
}

fn ensureTapSnapshot(self: *Launch) ![]const u8 {
    if (self.tap_snapshot_directory) |path| {
        return path;
    }
    var nonce: [16]u8 = undefined;
    try self.process.io.randomSecure(&nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const path = try std.fmt.bufPrint(&self.tap_snapshot_buffer, "/tmp/telar-tap-workers-{d}-{s}", .{ std.c.getuid(), &nonce_hex });
    try std.Io.Dir.cwd().createDir(self.process.io, path, std.Io.File.Permissions.fromMode(0o700));
    self.tap_snapshot_directory = path;
    return path;
}

pub fn runtimeInitialization(self: *const Launch) backend.Initialization {
    return .{
        .dependencies = .{
            .io = self.process.io,
            .allocator = self.process.gpa,
        },
        .options = .{
            .endpoint = self.connector.endpointPath(),
            .own_log = self.options.mode == .daemonized,
            .graphics = self.options.graphics,
            .environment = self.process.minimal.environ,
            .history_path = self.history_path.path,
            .history_filters = self.history_filters,
            .history_output_capture = self.history_output_capture,
            .proxy = self.proxy_options,
            .proxy_system_trusted = self.proxy_system_trusted,
            .plugins = self.tap_specs[0..self.tap_spec_count],
            .agent_descriptions = self.agent_description_options,
            .engine = self.engine_options,
            .agent_manifests = self.agent_manifests,
            .session_path = self.session_path,
            .resume_agents = self.session_resume_agents,
        },
    };
}

pub fn launchDaemon(self: *const Launch) !void {
    if (std.c.setsid() < 0) {
        return error.DetachFailed;
    }

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(self.process.io, &executable_buffer)];
    var pane_mib_buffer: [32]u8 = undefined;
    const pane_mib = try std.fmt.bufPrint(&pane_mib_buffer, "{d}", .{self.options.graphics.pane_bytes / (1024 * 1024)});
    var global_mib_buffer: [32]u8 = undefined;
    const global_mib = try std.fmt.bufPrint(&global_mib_buffer, "{d}", .{self.options.graphics.global_bytes / (1024 * 1024)});
    var argv: [14][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{
        executable,
        "server",
        "--daemonized",
        "--socket",
        self.connector.endpointPath(),
        "--graphics-pane-mib",
        pane_mib,
        "--graphics-global-mib",
        global_mib,
    }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    if (self.options.fresh) {
        argv[argc] = "--fresh";
        argc += 1;
    }
    if (self.options.config) |path| {
        argv[argc] = "--config";
        argv[argc + 1] = std.mem.span(path);
        argc += 2;
    } else if (self.options.no_config) {
        argv[argc] = "--no-config";
        argc += 1;
    }
    if (self.options.profile) |profile| {
        argv[argc] = "--profile";
        argv[argc + 1] = std.mem.span(profile);
        argc += 2;
    }

    // Until it holds the listener and opens its own log, the runtime's
    // standard error is this launch's start log: a runtime that never
    // starts leaves its reason there.
    const start_log = openStartLog(self.process.io, self.connector.endpointPath()) catch null;
    defer if (start_log) |file| {
        file.close(self.process.io);
    };

    const daemon = try std.process.spawn(self.process.io, .{
        .argv = argv[0..argc],
        .cwd = .{ .path = "/" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = if (start_log) |file| .{ .file = file } else .ignore,
    });
    _ = daemon;
}

/// Opens `<endpoint>.runtime.start.log` for this launch, replacing the last
/// launch's: owner-only, never rotated, since only what happens before the
/// listener lands in it.
fn openStartLog(io: std.Io, endpoint: []const u8) !std.Io.File {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ endpoint, core.DiagnosticLogName.runtime_start_log_suffix });

    return std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
}

pub fn deinit(self: *Launch) void {
    if (self.tap_snapshot_directory) |directory| {
        std.Io.Dir.cwd().deleteTree(self.process.io, directory) catch {};
        self.tap_snapshot_directory = null;
    }
    if (self.default_proxy_directory) |directory| {
        self.process.gpa.free(directory);
        self.default_proxy_directory = null;
    }
    if (self.configured_proxy_directory) |directory| {
        self.process.gpa.free(directory);
        self.configured_proxy_directory = null;
    }
    if (self.config_generation) |generation| {
        generation.deinit();
        self.config_generation = null;
    }
}
