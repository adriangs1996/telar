//! Runtime-facing proxy capability.
//!
//! Credentials are generated, registered, validated, and erased inside this
//! package. Runtime and pane state only see pane keys and observations.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");
const pty = @import("../pty/root.zig");
const identity = @import("identity.zig");
const middleware = @import("middleware.zig");
const service_mod = @import("service.zig");

const Io = std.Io;

pub const PaneKey = pane_mod.PaneKey;
pub const ObservationPhase = middleware.Phase;
pub const ObservationProtocol = middleware.Protocol;

pub const Config = struct {
    key_path: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
};

pub const Observation = struct {
    pane: PaneKey,
    provider: core.schema.AgentProvider,
    phase: ObservationPhase,
    protocol: ObservationProtocol,
    connection_id: u64,
    stream_id: u32 = 0,
    status_code: u16 = 0,
    observed_at_ms: i64,
};

pub const MetricsSnapshot = struct {
    active_connections: u32 = 0,
    queued_events: u64 = 0,
    event_queue_high_water: u64 = 0,
    dropped_events: u64 = 0,
    rejected_connections: u64 = 0,
    invalid_authorization_rejections: u64 = 0,
    unknown_credential_rejections: u64 = 0,
    connection_limit_drops: u64 = 0,
    h2_decode_failures: u64 = 0,
    passthrough_connections: u64 = 0,
    upstream_connect_failures: u64 = 0,
    tls_context_failures: u64 = 0,
    tls_upstream_handshake_failures: u64 = 0,
    tls_downstream_handshake_failures: u64 = 0,
    tls_mint_failures: u64 = 0,
};

/// Ephemeral child environment. Its proxy credential is scrubbed by
/// `pty.Environment.deinit`; the runtime must not retain or inspect it.
pub const PaneEnvironment = struct {
    value: pty.Environment,

    pub fn environment(pane_environment: *const PaneEnvironment) *const pty.Environment {
        return &pane_environment.value;
    }

    pub fn deinit(pane_environment: *PaneEnvironment) void {
        pane_environment.value.deinit();
    }
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    service: *service_mod.Service,

    pub fn create(io: Io, gpa: std.mem.Allocator, config: Config) !*Proxy {
        const service = try service_mod.Service.create(io, gpa, .{
            .key = config.key_path,
            .certificate = config.certificate_path,
            .bundle = config.bundle_path,
            .passthrough_hosts = config.passthrough_hosts,
        });
        errdefer service.destroy();
        const proxy = try gpa.create(Proxy);
        proxy.* = .{ .gpa = gpa, .service = service };
        return proxy;
    }

    pub fn destroy(proxy: *Proxy) void {
        const gpa = proxy.gpa;
        proxy.service.destroy();
        gpa.destroy(proxy);
    }

    pub fn run(proxy: *Proxy) anyerror!void {
        return proxy.service.run();
    }

    pub fn closeObservations(proxy: *Proxy, io: Io) void {
        proxy.service.events.close(io);
    }

    pub fn registerPane(proxy: *Proxy, key: PaneKey, inherited: std.process.Environ) !PaneEnvironment {
        var credential: identity.Credential = .{
            .pane_id = key.id,
            .pane_generation = key.generation,
            .token = identity.randomToken(proxy.service.io),
        };
        defer std.crypto.secureZero(u8, &credential.token);
        try proxy.service.registerCredential(credential);
        errdefer proxy.service.unregisterCredential(credential);

        var url_buffer: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &url_buffer);
        const proxy_url = try proxy.service.credentialUrl(&url_buffer, credential);
        const overrides = environmentOverrides(
            proxy_url,
            proxy.service.certificate_path,
            proxy.service.bundle_path,
        );
        return .{ .value = try pty.Environment.initWithOverrides(
            proxy.gpa,
            inherited,
            "telar",
            &overrides,
        ) };
    }

    pub fn revokePane(proxy: *Proxy, key: PaneKey) void {
        proxy.service.unregisterPane(key.id, key.generation);
    }

    /// Revocation rejects new tunnels and filters both queued and subsequent
    /// observations. A tunnel already authenticated keeps forwarding bytes.
    pub fn receive(proxy: *Proxy, io: Io) anyerror!Observation {
        var event = try proxy.service.receive(io);
        defer std.crypto.secureZero(u8, &event.credential.token);
        return .{
            .pane = .{
                .id = event.credential.pane_id,
                .generation = event.credential.pane_generation,
            },
            .provider = event.provider,
            .phase = event.phase,
            .protocol = event.protocol,
            .connection_id = event.connection_id,
            .stream_id = event.stream_id,
            .status_code = event.status_code,
            .observed_at_ms = event.observed_at_ms,
        };
    }

    pub fn metrics(proxy: *const Proxy) MetricsSnapshot {
        const service = proxy.service;
        return .{
            .active_connections = service.active_connections.load(.monotonic),
            .queued_events = service.queued_events.load(.monotonic),
            .event_queue_high_water = service.event_queue_high_water.load(.monotonic),
            .dropped_events = service.dropped_events.load(.monotonic),
            .rejected_connections = service.rejected_connections.load(.monotonic),
            .invalid_authorization_rejections = service.invalid_authorization_rejections.load(.monotonic),
            .unknown_credential_rejections = service.unknown_credential_rejections.load(.monotonic),
            .connection_limit_drops = service.connection_limit_drops.load(.monotonic),
            .h2_decode_failures = service.h2_decode_failures.load(.monotonic),
            .passthrough_connections = service.passthrough_connections.load(.monotonic),
            .upstream_connect_failures = service.upstream_connect_failures.load(.monotonic),
            .tls_context_failures = service.tls_context_failures.load(.monotonic),
            .tls_upstream_handshake_failures = service.tls_upstream_handshake_failures.load(.monotonic),
            .tls_downstream_handshake_failures = service.tls_downstream_handshake_failures.load(.monotonic),
            .tls_mint_failures = service.tls_mint_failures.load(.monotonic),
        };
    }
};

const environment_override_count = 11;

fn environmentOverrides(
    proxy_url: []const u8,
    certificate_path: []const u8,
    bundle_path: []const u8,
) [environment_override_count]pty.Environment.Override {
    return .{
        .{ .name = "HTTPS_PROXY", .value = proxy_url },
        .{ .name = "https_proxy", .value = proxy_url },
        .{ .name = "NODE_USE_ENV_PROXY", .value = "1" },
        .{ .name = "NODE_EXTRA_CA_CERTS", .value = certificate_path },
        .{ .name = "SSL_CERT_FILE", .value = bundle_path },
        .{ .name = "CURL_CA_BUNDLE", .value = bundle_path },
        .{ .name = "REQUESTS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "AWS_CA_BUNDLE", .value = bundle_path },
        .{ .name = "GIT_SSL_CAINFO", .value = bundle_path },
        .{ .name = "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", .value = bundle_path },
        .{ .name = "TELAR_PROXY_TLS", .value = "1" },
    };
}

test "proxy environment covers Git and Google Cloud trust stores" {
    const overrides = environmentOverrides(
        "http://127.0.0.1:45100",
        "/state/ca-cert.pem",
        "/state/ca-bundle.pem",
    );
    try std.testing.expectEqualStrings("GIT_SSL_CAINFO", overrides[8].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[8].value);
    try std.testing.expectEqualStrings("CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE", overrides[9].name);
    try std.testing.expectEqualStrings("/state/ca-bundle.pem", overrides[9].value);
}

test "pane registration owns and disposes its ephemeral environment" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const proxy = try Proxy.create(io, gpa, .{
        .key_path = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate_path = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle_path = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
    });
    defer proxy.destroy();

    var inherited_map = std.process.Environ.Map.init(gpa);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    const inherited_block = try inherited_map.createPosixBlock(gpa, .{});
    defer inherited_block.deinit(gpa);
    const key: PaneKey = .{ .id = try core.schema.id.pane(7), .generation = 2 };
    var environment = try proxy.registerPane(key, .{ .block = inherited_block });
    const child: std.process.Environ = .{ .block = environment.environment().block };
    try std.testing.expect(std.mem.startsWith(
        u8,
        std.process.Environ.getPosix(child, "HTTPS_PROXY").?,
        "http://telar:7.2.",
    ));
    environment.deinit();
    proxy.revokePane(key);
}

test {
    std.testing.refAllDecls(@import("ca.zig"));
    std.testing.refAllDecls(@import("h2.zig"));
    std.testing.refAllDecls(@import("http/root.zig"));
    std.testing.refAllDecls(identity);
    std.testing.refAllDecls(middleware);
    std.testing.refAllDecls(@import("provider/root.zig"));
    std.testing.refAllDecls(service_mod);
    std.testing.refAllDecls(@import("sse.zig"));
    std.testing.refAllDecls(@import("tls.zig"));
}
