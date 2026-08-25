//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const core = @import("telar-core");
const ca = @import("ca.zig");
const h2 = @import("h2.zig");
const http = @import("http.zig");
const identity = @import("identity.zig");
const middleware = @import("middleware.zig");
const tls = @import("tls.zig");

const Io = std.Io;
const net = Io.net;
const schema = core.schema;

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;
pub const max_connections: u32 = 64;
pub const event_capacity = 256;
pub const max_credentials = schema.max_agent_snapshot_entries;

pub const Paths = struct {
    key: []const u8,
    certificate: []const u8,
    bundle: []const u8,
};

pub const Service = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    port: u16,
    authority: ca.Authority,
    roots: tls.Roots,
    certificate_path: []const u8,
    bundle_path: []const u8,
    credentials: CredentialRegistry = .{},
    pipeline: middleware.Pipeline = .{},
    transforms: middleware.TransformPipeline = .{},
    configuration_mutex: Io.Mutex = .init,
    started: bool = false,
    event_storage: [event_capacity]middleware.Event = undefined,
    events: Io.Queue(middleware.Event),
    dropped_events: std.atomic.Value(u64) = .init(0),
    rejected_connections: std.atomic.Value(u64) = .init(0),
    connection_limit_drops: std.atomic.Value(u64) = .init(0),
    h2_decode_failures: std.atomic.Value(u64) = .init(0),
    active_connections: std.atomic.Value(u32) = .init(0),
    next_connection_id: std.atomic.Value(u64) = .init(1),

    pub fn create(
        io: Io,
        gpa: std.mem.Allocator,
        paths: Paths,
    ) !*Service {
        var authority = try ca.Authority.loadOrCreate(
            io,
            gpa,
            paths.key,
            paths.certificate,
        );
        defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
        try authority.writeBundle(io, gpa, paths.bundle);
        var roots = try tls.Roots.load(io, gpa);
        errdefer roots.deinit(gpa);
        var bound = try listen(io);
        errdefer bound.listener.deinit(io);
        const service = try gpa.create(Service);
        errdefer gpa.destroy(service);
        service.* = .{
            .io = io,
            .gpa = gpa,
            .listener = bound.listener,
            .port = bound.port,
            .authority = authority,
            .roots = roots,
            .certificate_path = paths.certificate,
            .bundle_path = paths.bundle,
            .events = undefined,
        };
        service.events = .init(&service.event_storage);
        try service.pipeline.add(.{ .context = service, .observe = enqueueEvent });
        return service;
    }

    pub fn destroy(service: *Service) void {
        const gpa = service.gpa;
        service.listener.deinit(service.io);
        service.roots.deinit(gpa);
        std.crypto.secureZero(u8, std.mem.asBytes(service));
        gpa.destroy(service);
    }

    pub fn run(service: *Service) anyerror!void {
        service.configuration_mutex.lockUncancelable(service.io);
        if (service.started) {
            service.configuration_mutex.unlock(service.io);
            return error.ProxyAlreadyRunning;
        }
        service.started = true;
        service.configuration_mutex.unlock(service.io);

        var connections: Io.Group = .init;
        defer connections.cancel(service.io);

        while (true) {
            const stream = service.listener.accept(service.io) catch |err| switch (err) {
                error.Canceled => |cancelled| return cancelled,
                error.SocketNotListening => return,
                else => continue,
            };
            const previous = service.active_connections.fetchAdd(1, .acq_rel);
            if (previous >= max_connections) {
                _ = service.active_connections.fetchSub(1, .acq_rel);
                stream.close(service.io);
                _ = service.connection_limit_drops.fetchAdd(1, .monotonic);
                continue;
            }
            connections.concurrent(service.io, tunnel, .{ service, stream }) catch {
                _ = service.active_connections.fetchSub(1, .acq_rel);
                stream.close(service.io);
            };
        }
    }

    pub fn receive(service: *Service, io: Io) anyerror!middleware.Event {
        return service.events.getOne(io);
    }

    pub fn credentialUrl(
        service: *const Service,
        buffer: []u8,
        credential: identity.Credential,
    ) ![]const u8 {
        return identity.formatUrl(buffer, service.port, credential);
    }

    /// Credentials are live capabilities, not merely well-formed proxy URL
    /// userinfo. Registration and revocation follow the pane lifecycle.
    pub fn registerCredential(service: *Service, credential: identity.Credential) !void {
        return service.credentials.register(service.io, credential);
    }

    pub fn unregisterCredential(service: *Service, credential: identity.Credential) void {
        service.credentials.remove(service.io, credential);
    }

    /// Register before `run` starts. The immutable pipeline can later be
    /// backed by a bounded worker without giving it access to tunnel state.
    pub fn addTransformer(service: *Service, transformer: middleware.Transformer) !void {
        service.configuration_mutex.lockUncancelable(service.io);
        defer service.configuration_mutex.unlock(service.io);
        if (service.started) return error.ProxyAlreadyRunning;
        return service.transforms.add(transformer);
    }

    fn enqueueEvent(context: *anyopaque, io: Io, event: middleware.Event) void {
        const service: *Service = @ptrCast(@alignCast(context));
        const queued = service.events.put(io, &.{event}, 0) catch 0;
        if (queued == 0) _ = service.dropped_events.fetchAdd(1, .monotonic);
    }
};

const CredentialRegistry = struct {
    mutex: Io.Mutex = .init,
    slots: [max_credentials]?identity.Credential = @splat(null),

    fn register(registry: *CredentialRegistry, io: Io, credential: identity.Credential) !void {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);
        var free: ?*?identity.Credential = null;
        for (&registry.slots) |*slot| {
            if (slot.*) |existing| {
                if (sameCredential(existing, credential)) return error.DuplicateProxyCredential;
            } else if (free == null) {
                free = slot;
            }
        }
        const destination = free orelse return error.TooManyProxyCredentials;
        destination.* = credential;
    }

    fn remove(registry: *CredentialRegistry, io: Io, credential: identity.Credential) void {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);
        for (&registry.slots) |*slot| {
            const existing = if (slot.*) |*value| value else continue;
            if (!sameCredential(existing.*, credential)) continue;
            std.crypto.secureZero(u8, &existing.token);
            slot.* = null;
            return;
        }
    }

    fn contains(registry: *CredentialRegistry, io: Io, credential: identity.Credential) bool {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);
        for (registry.slots) |slot| {
            const existing = slot orelse continue;
            if (sameCredential(existing, credential)) return true;
        }
        return false;
    }
};

fn sameCredential(left: identity.Credential, right: identity.Credential) bool {
    if (left.pane_id != right.pane_id or left.pane_generation != right.pane_generation)
        return false;
    return std.crypto.timing_safe.eql(
        [identity.token_bytes]u8,
        left.token,
        right.token,
    );
}

const Bound = struct { listener: net.Server, port: u16 };

fn listen(io: Io) !Bound {
    var port = first_port;
    while (port < first_port + port_attempts) : (port += 1) {
        const address = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.ProxyPortUnavailable;
}

const TunnelContext = struct {
    service: *Service,
    credential: identity.Credential,
    provider: schema.AgentProvider,
    connection_id: u64,
    protocol: middleware.Protocol,
    status_code: u16 = 0,

    fn publish(context: *TunnelContext, phase: middleware.Phase, stream_id: u32) void {
        context.publishStatus(phase, stream_id, context.status_code);
    }

    fn publishH2(context: *TunnelContext, phase: middleware.Phase, stream_id: u32, status_code: u16) void {
        context.publishStatus(phase, stream_id, status_code);
    }

    fn publishStatus(context: *TunnelContext, phase: middleware.Phase, stream_id: u32, status_code: u16) void {
        context.service.pipeline.publish(context.service.io, .{
            .credential = context.credential,
            .provider = context.provider,
            .phase = phase,
            .protocol = context.protocol,
            .connection_id = context.connection_id,
            .stream_id = stream_id,
            .status_code = status_code,
            .observed_at_ms = Io.Timestamp.now(context.service.io, .real).toMilliseconds(),
        });
    }

    fn transformContext(
        context: *const TunnelContext,
        direction: middleware.Direction,
        kind: middleware.HeaderKind,
        stream_id: u32,
    ) middleware.TransformContext {
        return .{
            .pane_id = context.credential.pane_id,
            .pane_generation = context.credential.pane_generation,
            .provider = context.provider,
            .protocol = context.protocol,
            .direction = direction,
            .kind = kind,
            .connection_id = context.connection_id,
            .stream_id = stream_id,
        };
    }
};

fn tunnel(service: *Service, stream: net.Stream) Io.Cancelable!void {
    defer {
        stream.close(service.io);
        _ = service.active_connections.fetchSub(1, .acq_rel);
    }
    var head: [32 * 1024]u8 = undefined;
    const head_len = readConnectHead(service.io, stream, &head) orelse return;
    defer std.crypto.secureZero(u8, head[0..head_len]);
    var credential = identity.parseProxyAuthorization(head[0..head_len]) orelse {
        _ = service.rejected_connections.fetchAdd(1, .monotonic);
        reply(service.io, stream, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer std.crypto.secureZero(u8, &credential.token);
    if (!service.credentials.contains(service.io, credential)) {
        _ = service.rejected_connections.fetchAdd(1, .monotonic);
        reply(service.io, stream, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\n\r\n");
        return;
    }
    const target = connectTarget(head[0..head_len]) orelse {
        reply(service.io, stream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    var context: TunnelContext = .{
        .service = service,
        .credential = credential,
        .provider = providerForHost(target.host),
        .connection_id = service.next_connection_id.fetchAdd(1, .monotonic),
        .protocol = .http11,
    };
    defer std.crypto.secureZero(u8, &context.credential.token);
    const host_name = net.HostName.init(target.host) catch {
        context.publish(.request_failed, 0);
        reply(service.io, stream, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    const upstream = connectUpstream(host_name, service.io, target.port) catch {
        context.publish(.request_failed, 0);
        reply(service.io, stream, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer upstream.close(service.io);
    reply(service.io, stream, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var cause: anyerror = error.Unknown;
    const session = tls.intercept(
        service.io,
        service.gpa,
        &service.authority,
        &service.roots,
        target.host,
        stream,
        upstream,
        &cause,
    ) catch {
        context.publish(.request_failed, 0);
        return;
    };
    defer session.deinit();

    context.protocol = if (session.negotiated() == .h2) .h2 else .http11;
    if (session.negotiated() == .h2) {
        var child_settings: h2.PeerSettings = .{};
        var origin_settings: h2.PeerSettings = .{};
        var outbound = if (service.transforms.len == 0)
            service.io.concurrent(relayH2Request, .{ session, &context }) catch return
        else
            service.io.concurrent(relayH2RequestTransformed, .{
                session,
                &context,
                &child_settings,
                &origin_settings,
            }) catch return;
        const response_stats = if (service.transforms.len == 0)
            h2.relay(
                session,
                .origin,
                .child,
                .response,
                &context,
                TunnelContext.publishH2,
            )
        else
            h2.relayTransformed(
                session,
                .origin,
                .child,
                .response,
                &origin_settings,
                &child_settings,
                &service.transforms,
                service.io,
                context.transformContext(.response, .response, 0),
                &context,
                TunnelContext.publishH2,
            );
        const request_stats = outbound.cancel(service.io);
        if (response_stats.decode_failed)
            _ = service.h2_decode_failures.fetchAdd(1, .monotonic);
        if (request_stats.decode_failed)
            _ = service.h2_decode_failures.fetchAdd(1, .monotonic);
        // The agent store ignores this connection-level sentinel after every
        // observed stream has settled. If the transport disappears first, it
        // clears the remaining streams and prevents a permanent working state.
        context.publish(.request_failed, 0);
        return;
    }

    while (true) {
        const request = http.relayHeadTransformed(
            session,
            .child,
            .origin,
            false,
            false,
            &service.transforms,
            service.io,
            context.transformContext(.request, .request, 0),
        ) orelse return;
        context.publish(.request_started, 0);
        const response = if (request.framing.hasBody()) response: {
            var event_storage: [2]HttpExchangeEvent = undefined;
            var exchange = Io.Select(HttpExchangeEvent).init(service.io, &event_storage);
            exchange.concurrent(.request_body, relayHttpRequestBody, .{
                session,
                request.framing,
                &context,
            }) catch {
                context.publish(.request_failed, 0);
                return;
            };
            exchange.concurrent(.response, relayHttpResponse, .{
                session,
                request.message.head_request,
                &context,
            }) catch {
                exchange.cancelDiscard();
                context.publish(.request_failed, 0);
                return;
            };
            defer exchange.cancelDiscard();

            var body_finished = false;
            while (true) switch (exchange.await() catch return) {
                .request_body => |forwarded| {
                    if (!forwarded) {
                        context.publish(.request_failed, 0);
                        return;
                    }
                    body_finished = true;
                },
                .response => |candidate| {
                    const final = candidate orelse {
                        context.publish(.request_failed, 0);
                        return;
                    };
                    // A final response may legally reject an upload before the
                    // client sends the body. The response has already reached
                    // the child; cancel the body reader and close this HTTP/1.1
                    // connection instead of waiting forever or reusing a stream
                    // whose request boundary is no longer known.
                    if (!body_finished) {
                        context.status_code = final.status_code;
                        context.publish(if (final.status_code >= 400)
                            .request_failed
                        else
                            .response_finished, 0);
                        return;
                    }
                    break :response final;
                },
            };
        } else relayHttpResponse(session, request.message.head_request, &context) orelse {
            context.publish(.request_failed, 0);
            return;
        };
        context.status_code = response.status_code;
        context.publish(if (response.status_code >= 400) .request_failed else .response_finished, 0);
        if (response.upgrade) {
            context.protocol = .upgraded;
            relayUpgrade(service.io, session, &context);
            return;
        }
        if (response.closes) return;
    }
}

fn relayH2Request(session: *tls.Session, context: *TunnelContext) h2.Stats {
    return h2.relay(
        session,
        .child,
        .origin,
        .request,
        context,
        TunnelContext.publishH2,
    );
}

fn relayH2RequestTransformed(
    session: *tls.Session,
    context: *TunnelContext,
    child_settings: *h2.PeerSettings,
    origin_settings: *h2.PeerSettings,
) h2.Stats {
    return h2.relayTransformed(
        session,
        .child,
        .origin,
        .request,
        child_settings,
        origin_settings,
        &context.service.transforms,
        context.service.io,
        context.transformContext(.request, .request, 0),
        context,
        TunnelContext.publishH2,
    );
}

fn ignoreActivity(_: *TunnelContext, _: usize) void {}

const HttpExchangeEvent = union(enum) {
    request_body: bool,
    response: ?http.Message,
};

fn relayHttpRequestBody(
    session: *tls.Session,
    framing: http.Framing,
    context: *TunnelContext,
) bool {
    return http.relayBody(
        session,
        .child,
        .origin,
        framing,
        context,
        ignoreActivity,
    );
}

fn relayHttpResponse(
    session: *tls.Session,
    response_to_head: bool,
    context: *TunnelContext,
) ?http.Message {
    while (true) {
        const head = http.relayHeadTransformed(
            session,
            .origin,
            .child,
            true,
            response_to_head,
            &context.service.transforms,
            context.service.io,
            context.transformContext(.response, .response, 0),
        ) orelse return null;
        if (!http.relayBody(
            session,
            .origin,
            .child,
            head.framing,
            context,
            responseActivity,
        )) return null;
        const candidate = head.message;
        if (!candidate.informational) return candidate;
    }
}

fn responseActivity(context: *TunnelContext, bytes: usize) void {
    if (bytes != 0) context.publish(.response_activity, 0);
}

fn relayUpgrade(io: Io, session: *tls.Session, context: *TunnelContext) void {
    var outbound = io.concurrent(pumpUpgrade, .{ session, tls.Session.Side.child, tls.Session.Side.origin, context }) catch return;
    pumpUpgrade(session, .origin, .child, context);
    outbound.await(io);
    context.publish(.response_finished, 0);
}

fn pumpUpgrade(
    session: *tls.Session,
    from: tls.Session.Side,
    to: tls.Session.Side,
    context: *TunnelContext,
) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (session.read(from, &buffer)) |len| {
        if (!session.writeAll(to, buffer[0..len])) break;
        if (from == .origin) context.publish(.response_activity, 0);
    }
    session.halfClose(to);
}

const Target = struct { host: []const u8, port: u16 };

fn connectTarget(head: []const u8) ?Target {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    if (!std.mem.eql(u8, parts.next() orelse return null, "CONNECT")) return null;
    const target = parts.next() orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return null;
    if (colon == 0) return null;
    return .{
        .host = target[0..colon],
        .port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch return null,
    };
}

fn readConnectHead(io: Io, stream: net.Stream, buffer: []u8) ?usize {
    var read_buffer: [8 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var len: usize = 0;
    while (len < buffer.len) {
        const byte = reader.interface.takeByte() catch return null;
        buffer[len] = byte;
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) return len;
    }
    return null;
}

fn reply(io: Io, stream: net.Stream, bytes: []const u8) void {
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

fn providerForHost(host: []const u8) schema.AgentProvider {
    if (hostMatches(host, "anthropic.com")) return .claude;
    if (hostMatches(host, "openai.com") or hostMatches(host, "chatgpt.com")) return .codex;
    return .unknown;
}

fn hostMatches(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len or host[host.len - domain.len - 1] != '.') return false;
    return std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain);
}

// Resolve asynchronously but connect sequentially. This avoids a Zig 0.16
// Darwin race where concurrent connect attempts can report EISCONN.
fn connectUpstream(host: net.HostName, io: Io, port: u16) !net.Stream {
    var lookup_storage: [32]net.HostName.LookupResult = undefined;
    var resolved: Io.Queue(net.HostName.LookupResult) = .init(&lookup_storage);
    var lookup = io.async(net.HostName.lookup, .{ host, io, &resolved, .{ .port = port } });
    defer lookup.cancel(io) catch {};
    var last_error: ?anyerror = null;
    while (resolved.getOne(io)) |result| switch (result) {
        .canonical_name => continue,
        .address => |address| {
            if (address.connect(io, .{ .mode = .stream })) |stream| return stream else |err| last_error = err;
        },
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {
            try lookup.await(io);
            return last_error orelse error.UnknownHostName;
        },
    }
}

test "provider domains require a label boundary" {
    try std.testing.expectEqual(schema.AgentProvider.claude, providerForHost("api.anthropic.com"));
    try std.testing.expectEqual(schema.AgentProvider.codex, providerForHost("ab.chatgpt.com"));
    try std.testing.expectEqual(schema.AgentProvider.unknown, providerForHost("evilopenai.com"));
}

test "CONNECT target parser rejects non-CONNECT requests" {
    try std.testing.expectEqualStrings("api.openai.com", connectTarget(
        "CONNECT api.openai.com:443 HTTP/1.1\r\n\r\n",
    ).?.host);
    try std.testing.expect(connectTarget("GET / HTTP/1.1\r\n\r\n") == null);
}

test "proxy credentials are revoked with their pane" {
    const io = std.testing.io;
    var registry: CredentialRegistry = .{};
    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .token = .{0x5a} ** identity.token_bytes,
    };
    try registry.register(io, credential);
    try std.testing.expect(registry.contains(io, credential));
    try std.testing.expectError(error.DuplicateProxyCredential, registry.register(io, credential));
    registry.remove(io, credential);
    try std.testing.expect(!registry.contains(io, credential));
}

test "loopback service rejects a CONNECT without a live pane capability" {
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
    const service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory}),
    });
    defer service.destroy();
    var worker = try io.concurrent(Service.run, .{service});
    defer worker.cancel(io) catch {};

    const address = try net.IpAddress.parse("127.0.0.1", service.port);
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    try writer.interface.writeAll("CONNECT api.openai.com:443 HTTP/1.1\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: [512]u8 = undefined;
    const response_len = try reader.interface.readSliceShort(&response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        response[0..response_len],
        "HTTP/1.1 407 Proxy Authentication Required\r\n",
    ));
}
