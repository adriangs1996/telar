//! Runtime-owned loopback ProxyTLS service.

const std = @import("std");
const core = @import("telar-core");
const diagnostics = core.diagnostics;
const ca = @import("ca.zig");
const connection_admission = @import("connection_admission.zig");
const connect_authentication = @import("connect_authentication.zig");
const credential_registry = @import("credential_registry.zig");
const h2 = @import("h2/root.zig");
const http = @import("http/root.zig");
const identity = @import("identity.zig");
const metrics_mod = @import("metrics.zig");
const middleware = @import("middleware.zig");
const observation_queue = @import("observation_queue.zig");
const passthrough_policy = @import("passthrough_policy.zig");
const provider = @import("provider/root.zig");
const tls = @import("tls.zig");
const tunnel_exchange = @import("tunnel/exchange.zig");
const tunnel_tls = @import("tunnel/tls.zig");

const Io = std.Io;
const net = Io.net;
const schema = core.schema;

pub const first_port: u16 = 45100;
pub const port_attempts: u16 = 128;
pub const max_connections: u32 = 64;
pub const event_capacity = observation_queue.capacity;

pub const Paths = struct {
    key: []const u8,
    certificate: []const u8,
    bundle: []const u8,
    passthrough_hosts: []const []const u8 = &.{},
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
    passthrough_hosts: passthrough_policy.Policy,
    credentials: credential_registry.Registry = .{},
    pipeline: middleware.Pipeline = .{},
    transforms: middleware.TransformPipeline = .{},
    has_custom_transformers: bool = false,
    configuration_mutex: Io.Mutex = .init,
    started: bool = false,
    observations: observation_queue.Channel = undefined,
    connection_slots: connection_admission.Slots = .init(max_connections),
    telemetry: metrics_mod.Counters = .{},
    next_connection_id: std.atomic.Value(u64) = .init(1),

    pub fn create(io: Io, gpa: std.mem.Allocator, paths: Paths) !*Service {
        const ca_resources: ca.Resources = .{ .io = io, .allocator = gpa };
        var authority = try ca.Authority.loadOrCreate(ca_resources, .{
            .key = paths.key,
            .certificate = paths.certificate,
        });
        defer std.crypto.secureZero(u8, std.mem.asBytes(&authority));
        try authority.writeBundle(ca_resources, paths.bundle);
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
            .passthrough_hosts = try .init(paths.passthrough_hosts),
            .observations = undefined,
        };
        service.observations.init(.{
            .context = service,
            .is_live = observationCredentialIsLive,
        });
        try service.pipeline.add(service.observations.observer());
        try service.transforms.add(provider.claudeRequestTransformer());
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
        const path = diagnostics.enter(.observation);
        defer path.restore();
        service.configuration_mutex.lockUncancelable(service.io);
        if (service.started) {
            service.configuration_mutex.unlock(service.io);
            return error.ProxyAlreadyRunning;
        }
        service.started = true;
        service.configuration_mutex.unlock(service.io);

        return ConnectionAdmission.run(service);
    }

    pub fn receive(service: *Service, io: Io) anyerror!middleware.Event {
        return service.observations.receive(io);
    }

    /// Returns one lock-free snapshot without exposing queue, admission, or
    /// counter storage to the caller.
    ///
    /// ```zig
    /// const snapshot = service.metrics();
    /// ```
    pub fn metrics(service: *const Service) metrics_mod.Snapshot {
        return service.telemetry.snapshot(.{
            .connections = service.connection_slots.snapshot(),
            .observations = service.observations.metrics(),
        });
    }

    pub fn credentialUrl(service: *const Service, buffer: []u8, credential: *const identity.Credential) ![]const u8 {
        return identity.formatUrl(buffer, service.port, credential);
    }

    /// Credentials are live capabilities, not merely well-formed proxy URL
    /// userinfo. Registration and revocation follow the pane lifecycle.
    ///
    /// ```zig
    /// try service.registerCredential(&credential);
    /// ```
    pub fn registerCredential(service: *Service, credential: *const identity.Credential) !void {
        return service.credentials.register(service.io, credential);
    }

    pub fn unregisterCredential(service: *Service, credential: *const identity.Credential) void {
        service.credentials.remove(service.io, credential);
    }

    pub fn unregisterPane(service: *Service, pane_id: schema.PaneId, pane_generation: u64) void {
        service.credentials.removePane(service.io, .{ .id = pane_id, .generation = pane_generation });
    }

    /// Register before `run` starts. The immutable pipeline can later be
    /// backed by a bounded worker without giving it access to tunnel state.
    ///
    /// ```zig
    /// try service.addTransformer(transformer);
    /// ```
    pub fn addTransformer(service: *Service, transformer: middleware.Transformer) !void {
        service.configuration_mutex.lockUncancelable(service.io);
        defer service.configuration_mutex.unlock(service.io);
        if (service.started) {
            return error.ProxyAlreadyRunning;
        }

        try service.transforms.add(transformer);
        service.has_custom_transformers = true;
    }
};

const connection_admission_port: connection_admission.Port(Service, net.Stream) = .{
    .accept = acceptConnection,
    .acquire = acquireConnection,
    .start = startConnection,
    .release = releaseConnection,
    .close = closeConnection,
    .cancel = cancelConnections,
};

const ConnectionAdmission = connection_admission.Runner(Service, net.Stream, connection_admission_port);

const connect_credential_port: connect_authentication.CredentialPort(Service) = .{
    .contains = containsCredential,
};

const ConnectAuthentication = connect_authentication.Command(Service, connect_credential_port);

fn acceptConnection(service: *Service) !net.Stream {
    return service.listener.accept(service.io);
}

fn acquireConnection(service: *Service) bool {
    return service.connection_slots.acquire();
}

fn startConnection(service: *Service, connections: *Io.Group, stream: net.Stream) !void {
    try connections.concurrent(service.io, tunnel, .{ service, stream });
}

fn releaseConnection(service: *Service) void {
    service.connection_slots.release();
}

fn closeConnection(service: *Service, stream: net.Stream) void {
    stream.close(service.io);
}

fn cancelConnections(service: *Service, connections: *Io.Group) void {
    connections.cancel(service.io);
}

fn containsCredential(service: *Service, credential: *const identity.Credential) bool {
    return service.credentials.contains(service.io, credential);
}

fn observationCredentialIsLive(context: *anyopaque, credential: *const identity.Credential) bool {
    const service: *Service = @ptrCast(@alignCast(context));
    return service.credentials.contains(service.io, credential);
}

const Bound = struct { listener: net.Server, port: u16 };

fn listen(io: Io) !Bound {
    var port = first_port;
    while (port < first_port + port_attempts) : (port += 1) {
        const address = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.ProxyPortUnavailable;
}

test "proxy listeners own distinct loopback ports" {
    const io = std.testing.io;
    var first = try listen(io);
    defer first.listener.deinit(io);
    var second = try listen(io);
    defer second.listener.deinit(io);
    try std.testing.expect(first.port != second.port);
}

const UpgradeRoute = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
};

const TunnelContext = tunnel_exchange.Exchange;

const Http1Context = struct {
    service: *Service,
    session: *tls.Session,
    tunnel: *TunnelContext,
    request: provider.RequestObserver = .{},
};

const http1_exchange_port: http.ExchangePort(Http1Context) = .{
    .io = http1Io,
    .relay_body = relayHttpRequestBody,
    .relay_response = relayHttpResponse,
};

const RelayHttp1Exchange = http.Exchange(Http1Context, http1_exchange_port);

const http1_connection_port: http.ConnectionPort(Http1Context) = .{
    .read_request = relayHttpRequestHead,
    .exchange = relayHttpExchange,
    .publish_request = publishHttpRequest,
    .publish_response = publishHttpResponse,
    .publish_failure = publishHttpFailure,
    .upgrade = upgradeHttpConnection,
};

const RelayHttp1Connection = http.Connection(Http1Context, http1_connection_port);

const H2Context = struct {
    service: *Service,
    session: *tls.Session,
    tunnel: *TunnelContext,
    responses: ?*provider.ResponseStreams,
    requests: ?*provider.RequestStreams = null,
};

const h2_connection_port: h2.ConnectionPort(H2Context) = .{
    .io = h2Io,
    .relay_request = relayH2Request,
    .relay_response = relayH2Response,
    .record_decode_failure = recordH2DecodeFailure,
    .settle = settleH2Connection,
};

const RelayH2Connection = h2.Connection(H2Context, h2_connection_port);

const H2EventObserver = struct {
    context: *TunnelContext,
    responses: ?*provider.ResponseStreams = null,
    requests: ?*provider.RequestStreams = null,

    /// Routes borrowed HTTP/2 observations through provider request and
    /// response semantics before publishing lifecycle evidence.
    ///
    /// ```zig
    /// observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = fragment } });
    /// ```
    pub fn emit(observer: *H2EventObserver, event: h2.Event) void {
        switch (event) {
            .lifecycle => |lifecycle| observer.observeLifecycle(lifecycle),
            .request_body => |body| {
                const requests = observer.requests orelse return;

                requests.feed(.{
                    .stream_id = body.stream_id,
                    .bytes = body.bytes,
                });
            },
            .request_finished => |finished| observer.finishRequest(finished.stream_id),
            .response_body => |body| {
                const responses = observer.responses orelse return;

                if (shouldInspectH2Body(body)) {
                    observer.context.record(.claude_sse_payload_fragment);

                    if (responses.feed(body.stream_id, body.bytes)) {
                        observer.context.publishStatus(.{ .phase = .provider_turn_completed, .stream_id = body.stream_id, .status_code = 0 });
                    }
                }
            },
        }
    }

    fn observeLifecycle(observer: *H2EventObserver, lifecycle: h2.Lifecycle) void {
        if (observer.shouldClassifyRequest(lifecycle)) {
            const requests = observer.requests.?;
            if (!requests.start(lifecycle.stream_id)) {
                publishH2RequestClass(observer.context, lifecycle.stream_id, .auxiliary);
            }

            return;
        }

        if (lifecycle.phase == .request_failed) {
            if (observer.requests) |requests| {
                requests.discard(lifecycle.stream_id);
            }
        }

        observer.context.publishStatus(.{
            .phase = lifecycle.phase,
            .stream_id = lifecycle.stream_id,
            .status_code = lifecycle.status_code,
        });

        if (observer.responses) |responses| {
            if (lifecycle.stream_id != 0 and
                (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed))
            {
                responses.finish(lifecycle.stream_id);
            }
        }
    }

    fn shouldClassifyRequest(observer: *const H2EventObserver, lifecycle: h2.Lifecycle) bool {
        return observer.context.provider == .claude and observer.requests != null and
            lifecycle.phase == .request_started;
    }

    fn finishRequest(observer: *H2EventObserver, stream_id: u32) void {
        const requests = observer.requests orelse return;
        const classification = requests.finish(stream_id) orelse return;
        publishH2RequestClass(observer.context, stream_id, classification);
    }
};

fn publishH2RequestClass(context: *TunnelContext, stream_id: u32, classification: provider.RequestClass) void {
    context.publishStatus(.{
        .phase = httpRequestPhase(classification),
        .stream_id = stream_id,
        .status_code = 0,
    });
}

fn shouldInspectH2Body(body: h2.ResponseBody) bool {
    return body.sse_body and body.status_code >= 200 and body.status_code < 300;
}

fn tunnel(service: *Service, stream: net.Stream) Io.Cancelable!void {
    const path = diagnostics.enter(.observation);
    defer path.restore();
    defer {
        stream.close(service.io);
        service.connection_slots.release();
    }
    var head: [http.max_head_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &head);
    const head_len = readConnectHead(service.io, stream, &head) orelse return;
    var authenticated = switch (ConnectAuthentication.execute(service, head[0..head_len])) {
        .authenticated => |value| value,
        .rejected => |rejection| {
            if (rejection.metric) |metric| {
                recordAuthenticationRejection(service, metric);
            }

            reply(service.io, stream, rejection.response);
            return;
        },
    };
    defer std.crypto.secureZero(u8, &authenticated.credential.token);
    const target = authenticated.target;
    var context: TunnelContext = .{
        .io = service.io,
        .pipeline = &service.pipeline,
        .telemetry = &service.telemetry,
        .credential = authenticated.credential,
        .provider = provider.identify(target.host.bytes),
        .connection_id = service.next_connection_id.fetchAdd(1, .monotonic),
        .protocol = .http11,
    };
    defer std.crypto.secureZero(u8, &context.credential.token);
    const upstream = connectUpstream(target.host, service.io, target.port) catch {
        service.telemetry.record(.upstream_connect_failure);
        context.publish(.request_failed, 0);
        reply(service.io, stream, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
        return;
    };
    defer upstream.close(service.io);
    reply(service.io, stream, "HTTP/1.1 200 Connection Established\r\n\r\n");

    var tls_establisher: tunnel_tls.Establisher = .{
        .resources = .{
            .io = service.io,
            .gpa = service.gpa,
            .authority = &service.authority,
            .roots = &service.roots,
            .passthrough = &service.passthrough_hosts,
            .telemetry = &service.telemetry,
        },
        .exchange = &context,
    };
    const route = tls_establisher.establish(.{
        .host = target.host.bytes,
        .child = stream,
        .origin = upstream,
    }) orelse return;

    var negotiated_h2 = false;
    const session = switch (route) {
        .passthrough => {
            relayPassthrough(service.io, stream, upstream);
            return;
        },
        .http11 => |established| established,
        .h2 => |established| block: {
            negotiated_h2 = true;
            break :block established;
        },
    };
    defer session.deinit();

    context.protocol = if (negotiated_h2) .h2 else .http11;
    if (negotiated_h2) {
        var response_streams = provider.ResponseStreams.init(service.gpa, context.provider);
        defer response_streams.deinit();
        var request_streams = provider.RequestStreams.init(context.provider);
        defer request_streams.deinit();
        var h2_context: H2Context = .{
            .service = service,
            .session = session,
            .tunnel = &context,
            .responses = if (context.provider == .claude) &response_streams else null,
            .requests = if (context.provider == .claude) &request_streams else null,
        };

        RelayH2Connection.run(&h2_context);
        return;
    }

    var http1_context: Http1Context = .{
        .service = service,
        .session = session,
        .tunnel = &context,
    };
    defer http1_context.request.deinit();
    RelayHttp1Connection.run(&http1_context);
}

fn recordAuthenticationRejection(service: *Service, rejection: connect_authentication.RejectionMetric) void {
    service.telemetry.record(.rejected_connection);
    switch (rejection) {
        .invalid_authorization => service.telemetry.record(.invalid_authorization_rejection),
        .unknown_credential => service.telemetry.record(.unknown_credential_rejection),
    }
}

fn h2Io(context: *H2Context) Io {
    return context.service.io;
}

fn relayH2Request(context: *H2Context, settings: *h2.Settings) h2.Stats {
    var observer: H2EventObserver = .{
        .context = context.tunnel,
        .requests = context.requests,
    };

    return h2.relay(context.session, h2RelayOptions(context, settings, .request), &observer);
}

fn relayH2Response(context: *H2Context, settings: *h2.Settings) h2.Stats {
    var observer: H2EventObserver = .{
        .context = context.tunnel,
        .responses = context.responses,
    };

    return h2.relay(context.session, h2RelayOptions(context, settings, .response), &observer);
}

fn h2RelayOptions(context: *H2Context, settings: *h2.Settings, direction: h2.Direction) h2.RelayOptions {
    const kind: middleware.HeaderKind = switch (direction) {
        .request => .request,
        .response => .response,
    };
    const transform_direction: middleware.Direction = switch (direction) {
        .request => .request,
        .response => .response,
    };

    return h2.relayOptions(direction, settings, .{
        .provider = context.tunnel.provider,
        .transformation = if (!shouldTransformH2(context, direction)) null else .{
            .pipeline = &context.service.transforms,
            .io = context.service.io,
            .context = context.tunnel.transformContext(.{ .direction = transform_direction, .kind = kind, .stream_id = 0 }),
        },
    });
}

fn shouldTransformH2(context: *const H2Context, direction: h2.Direction) bool {
    if (context.service.has_custom_transformers) {
        return true;
    }

    return context.tunnel.provider == .claude and direction == .request;
}

fn recordH2DecodeFailure(context: *H2Context, _: h2.Direction) void {
    context.service.telemetry.record(.h2_decode_failure);
}

fn settleH2Connection(context: *H2Context) void {
    // A stream-zero failure settles any exchange left open when the transport
    // disappeared. The agent model ignores it after every stream settled.
    context.tunnel.publish(.request_failed, 0);
}

const HttpRequestObserver = struct {
    request: *provider.RequestObserver,

    /// Feeds decoded payload bytes to the active provider request classifier.
    ///
    /// ```zig
    /// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
    /// ```
    pub fn observe(observer: HttpRequestObserver, fragment: http.BodyFragment) void {
        observer.request.feed(fragment.payload);
    }
};

fn http1Io(context: *Http1Context) Io {
    return context.service.io;
}

fn relayHttpRequestHead(context: *Http1Context) ?http.RequestHead {
    context.request.deinit();

    const parsed = http.relayHeadTransformed(context.session, .{
        .route = .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
            .provider = context.tunnel.provider,
        },
        .pipeline = &context.service.transforms,
        .io = context.service.io,
        .context = context.tunnel.transformContext(.{ .direction = .request, .kind = .request, .stream_id = 0 }),
    }) orelse return null;

    return .{
        .classification = parsed.classification,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}

fn relayHttpExchange(context: *Http1Context, request: http.RequestHead) http.ExchangeOutcome {
    return RelayHttp1Exchange.execute(context, request);
}

fn relayHttpRequestBody(context: *Http1Context, framing: http.BodyPlan) bool {
    const inspect = context.request.isActive();
    defer {
        if (inspect) {
            context.request.deinit();
        }
    }
    const forwarded = http.relayBody(
        context.session,
        .{ .from = .child, .to = .origin, .framing = framing },
        HttpRequestObserver{ .request = &context.request },
    );

    if (forwarded and inspect) {
        finishHttpRequest(context);
    }

    return forwarded;
}

fn finishHttpRequest(context: *Http1Context) void {
    context.tunnel.publish(httpRequestPhase(context.request.finish()), 0);
}

fn relayHttpResponse(context: *Http1Context, request: http.RequestHead) ?http.ResponseHead {
    while (true) {
        const head = http.relayHeadTransformed(context.session, .{
            .route = .{
                .from = .origin,
                .to = .child,
                .is_response = true,
                .response_to_head = request.response_context == .head_request,
            },
            .pipeline = &context.service.transforms,
            .io = context.service.io,
            .context = context.tunnel.transformContext(.{ .direction = .response, .kind = .response, .stream_id = 0 }),
        }) orelse return null;

        var observer: HttpResponseObserver = .init(
            context.tunnel,
            shouldInspectHttpResponse(request, head),
        );
        const forwarded = http.relayBody(
            context.session,
            .{ .from = .origin, .to = .child, .framing = head.framing },
            &observer,
        );
        observer.deinit();

        if (!forwarded) {
            return null;
        }

        if (!head.message.informational) {
            return semanticResponseHead(head);
        }
    }
}

fn semanticResponseHead(head: http.Head) http.ResponseHead {
    return .{
        .status_code = head.message.status_code,
        .body = head.framing,
        .kind = if (head.message.informational)
            .informational
        else if (head.message.upgrade)
            .upgrade
        else
            .final,
        .connection = if (head.message.closes) .close else .keep_alive,
    };
}

fn publishHttpRequest(context: *Http1Context, request: http.RequestHead) void {
    if (shouldClassifyHttpRequest(context, request)) {
        context.request.init(context.tunnel.provider);
        return;
    }

    const classification: http.RequestClass = if (context.tunnel.provider == .claude and
        request.classification == .inference)
        .auxiliary
    else
        request.classification;
    context.tunnel.publish(httpRequestPhase(classification), 0);
}

fn shouldClassifyHttpRequest(context: *const Http1Context, request: http.RequestHead) bool {
    return context.tunnel.provider == .claude and request.classification == .inference and
        request.body.hasBody();
}

fn httpRequestPhase(classification: http.RequestClass) middleware.Phase {
    return switch (classification) {
        .inference => .request_started,
        .auxiliary => .auxiliary_request_started,
    };
}

fn publishHttpResponse(context: *Http1Context, response: http.ResponseHead) void {
    context.tunnel.status_code = response.status_code;
    context.tunnel.publish(httpResponsePhase(response.status_code), 0);
}

fn httpResponsePhase(status_code: u16) middleware.Phase {
    return if (status_code >= 400) .request_failed else .response_finished;
}

fn publishHttpFailure(context: *Http1Context) void {
    context.tunnel.publish(.request_failed, 0);
}

fn upgradeHttpConnection(context: *Http1Context) void {
    context.tunnel.protocol = .upgraded;
    relayUpgrade(context.service.io, context.session, context.tunnel);
}

const HttpResponseObserver = struct {
    context: *TunnelContext,
    response: provider.ResponseObserver,
    inspect_payload: bool,

    fn init(context: *TunnelContext, inspect_payload: bool) HttpResponseObserver {
        return .{
            .context = context,
            .response = .init(context.provider),
            .inspect_payload = inspect_payload,
        };
    }

    pub fn observe(observer: *HttpResponseObserver, fragment: http.BodyFragment) void {
        if (fragment.forwarded_bytes != 0) {
            observer.context.publish(.response_activity, 0);
        }

        if (observer.inspect_payload and fragment.payload.len != 0) {
            if (observer.response.provider == .claude) {
                observer.context.record(.claude_sse_payload_fragment);
            }

            if (observer.response.feed(fragment.payload)) {
                observer.context.publish(.provider_turn_completed, 0);
            }
        }
    }

    fn deinit(observer: *HttpResponseObserver) void {
        observer.response.deinit();
        observer.inspect_payload = false;
    }
};

fn shouldInspectHttpResponse(request: http.RequestHead, head: http.Head) bool {
    return request.classification == .inference and
        head.sse_body and
        head.message.status_code >= 200 and head.message.status_code < 300;
}

const TestServiceFixture = struct {
    temp: std.testing.TmpDir = undefined,
    key: [std.fs.max_path_bytes]u8 = undefined,
    certificate: [std.fs.max_path_bytes]u8 = undefined,
    bundle: [std.fs.max_path_bytes]u8 = undefined,
    service: ?*Service = null,

    fn init(fixture: *TestServiceFixture, io: Io, gpa: std.mem.Allocator) !void {
        fixture.temp = std.testing.tmpDir(.{});
        errdefer fixture.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_len = try fixture.temp.dir.realPath(io, &directory_buffer);
        const directory = directory_buffer[0..directory_len];
        fixture.service = try Service.create(io, gpa, .{
            .key = try std.fmt.bufPrint(&fixture.key, "{s}/ca-key.pem", .{directory}),
            .certificate = try std.fmt.bufPrint(&fixture.certificate, "{s}/ca-cert.pem", .{directory}),
            .bundle = try std.fmt.bufPrint(&fixture.bundle, "{s}/ca-bundle.pem", .{directory}),
        });
    }

    fn deinit(fixture: *TestServiceFixture) void {
        fixture.service.?.destroy();
        fixture.temp.cleanup();
    }
};

const ExpectedTestObservation = struct {
    phase: middleware.Phase,
    protocol: middleware.Protocol,
    connection_id: u64,
    stream_id: u32,
};

fn expectTestObservations(service: *Service, expected: []const ExpectedTestObservation) !void {
    try std.testing.expectEqual(expected.len, service.observations.metrics().queued);

    for (expected) |wanted| {
        var event = try service.receive(std.testing.io);
        defer std.crypto.secureZero(u8, &event.credential.token);

        try std.testing.expectEqual(wanted.phase, event.phase);
        try std.testing.expectEqual(schema.AgentProvider.claude, event.provider);
        try std.testing.expectEqual(wanted.protocol, event.protocol);
        try std.testing.expectEqual(wanted.connection_id, event.connection_id);
        try std.testing.expectEqual(wanted.stream_id, event.stream_id);
    }
}

const test_claude_end_turn_event =
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n" ++
    "\n";

const test_claude_primary_request =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"private\"}]," ++
    "\"tools\":[{\"name\":\"Read\"}],\"stream\":true}";

const test_claude_startup_request =
    "{\"model\":\"claude-haiku\",\"max_tokens\":1," ++
    "\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}";

fn testingTunnel(service: *Service, protocol: middleware.Protocol, connection_id: u64) !TunnelContext {
    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(47),
        .pane_generation = 53,
        .token = .{0x35} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);

    return .{
        .io = service.io,
        .pipeline = &service.pipeline,
        .telemetry = &service.telemetry,
        .credential = credential,
        .provider = .claude,
        .connection_id = connection_id,
        .protocol = protocol,
    };
}

test "HTTP1 Claude request bodies refine route candidates before publication" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    var tunnel_context = try testingTunnel(service, .http11, 59);
    var context: Http1Context = .{
        .service = service,
        .session = undefined,
        .tunnel = &tunnel_context,
    };
    defer context.request.deinit();
    const candidate: http.RequestHead = .{
        .classification = .inference,
        .body = .{ .content_length = test_claude_startup_request.len },
        .response_context = .normal,
    };
    const request_observer: HttpRequestObserver = .{ .request = &context.request };

    publishHttpRequest(&context, candidate);
    try std.testing.expectEqual(@as(u64, 0), service.observations.metrics().queued);
    request_observer.observe(.{
        .payload = test_claude_startup_request,
        .forwarded_bytes = test_claude_startup_request.len,
    });
    finishHttpRequest(&context);
    context.request.deinit();

    publishHttpRequest(&context, .{
        .classification = .inference,
        .body = .none,
        .response_context = .normal,
    });

    var primary = candidate;
    primary.body = .{ .content_length = test_claude_primary_request.len };
    publishHttpRequest(&context, primary);
    const split = test_claude_primary_request.len / 2;
    request_observer.observe(.{
        .payload = test_claude_primary_request[0..split],
        .forwarded_bytes = split,
    });
    request_observer.observe(.{
        .payload = test_claude_primary_request[split..],
        .forwarded_bytes = test_claude_primary_request.len - split,
    });
    finishHttpRequest(&context);

    try expectTestObservations(service, &.{
        .{ .phase = .auxiliary_request_started, .protocol = .http11, .connection_id = 59, .stream_id = 0 },
        .{ .phase = .auxiliary_request_started, .protocol = .http11, .connection_id = 59, .stream_id = 0 },
        .{ .phase = .request_started, .protocol = .http11, .connection_id = 59, .stream_id = 0 },
    });
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_inference_requests);
}

test "HTTP2 Claude request bodies refine interleaved route candidates per stream" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    var tunnel_context = try testingTunnel(service, .h2, 61);
    var requests = provider.RequestStreams.init(.claude);
    defer requests.deinit();
    var observer: H2EventObserver = .{
        .context = &tunnel_context,
        .requests = &requests,
    };

    observer.emit(.{ .lifecycle = .{ .phase = .request_started, .stream_id = 63, .status_code = 0 } });
    observer.emit(.{ .lifecycle = .{ .phase = .request_started, .stream_id = 65, .status_code = 0 } });
    try std.testing.expectEqual(@as(u64, 0), service.observations.metrics().queued);

    const primary_split = test_claude_primary_request.len / 2;
    const startup_split = test_claude_startup_request.len / 2;
    observer.emit(.{ .request_body = .{ .stream_id = 63, .bytes = test_claude_primary_request[0..primary_split] } });
    observer.emit(.{ .request_body = .{ .stream_id = 65, .bytes = test_claude_startup_request[0..startup_split] } });
    observer.emit(.{ .request_body = .{ .stream_id = 63, .bytes = test_claude_primary_request[primary_split..] } });
    observer.emit(.{ .request_body = .{ .stream_id = 65, .bytes = test_claude_startup_request[startup_split..] } });
    observer.emit(.{ .request_finished = .{ .stream_id = 65 } });
    observer.emit(.{ .request_finished = .{ .stream_id = 63 } });

    try expectTestObservations(service, &.{
        .{ .phase = .auxiliary_request_started, .protocol = .h2, .connection_id = 61, .stream_id = 65 },
        .{ .phase = .request_started, .protocol = .h2, .connection_id = 61, .stream_id = 63 },
    });
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_inference_requests);
}

test "provider payload inspection uses successful response bodies as evidence" {
    const request: http.RequestHead = .{
        .classification = .inference,
        .body = .none,
        .response_context = .normal,
    };
    const successful: http.Head = .{
        .message = .{ .status_code = 200 },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = true,
    };

    try std.testing.expect(shouldInspectHttpResponse(request, successful));
    try std.testing.expect(!shouldInspectHttpResponse(.{
        .classification = .auxiliary,
        .body = .none,
        .response_context = .normal,
    }, successful));

    var non_sse = successful;
    non_sse.sse_body = false;
    try std.testing.expect(!shouldInspectHttpResponse(request, non_sse));

    inline for (.{ @as(u16, 199), 300, 429, 500 }) |status_code| {
        var failed = successful;
        failed.message.status_code = status_code;
        try std.testing.expect(!shouldInspectHttpResponse(request, failed));
        try std.testing.expect(!shouldInspectH2Body(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    inline for (.{ @as(u16, 200), 204, 299 }) |status_code| {
        try std.testing.expect(shouldInspectH2Body(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    try std.testing.expect(!shouldInspectH2Body(.{
        .stream_id = 1,
        .status_code = 200,
        .sse_body = false,
        .bytes = "",
    }));
}

test "service negotiates identity encoding for Claude message requests" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    var headers: middleware.Headers = .{};
    try headers.append(.{ .name = ":method", .value = "POST" });
    try headers.append(.{ .name = ":path", .value = "/v1/messages" });
    try headers.append(.{ .name = "accept-encoding", .value = "gzip, br" });

    const changed = service.transforms.apply(.{
        .io = std.testing.io,
        .context = .{
            .pane_id = @enumFromInt(1),
            .pane_generation = 1,
            .provider = .claude,
            .protocol = .http11,
            .direction = .request,
            .kind = .request,
            .connection_id = 1,
            .stream_id = 0,
        },
        .headers = &headers,
    });

    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("identity", headers.find("accept-encoding").?);
}

test "built-in Claude negotiation transforms only HTTP2 request heads" {
    var fixture: TestServiceFixture = .{};
    try fixture.init(std.testing.io, std.testing.allocator);
    defer fixture.deinit();
    const service = fixture.service.?;
    var tunnel_context = try testingTunnel(service, .h2, 1);
    var context: H2Context = .{
        .service = service,
        .session = undefined,
        .tunnel = &tunnel_context,
        .responses = null,
    };

    try std.testing.expect(shouldTransformH2(&context, .request));
    try std.testing.expect(!shouldTransformH2(&context, .response));

    tunnel_context.provider = .codex;
    try std.testing.expect(!shouldTransformH2(&context, .request));
    try std.testing.expect(!shouldTransformH2(&context, .response));

    const Preserve = struct {
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .preserve;
        }
    };
    var ignored: u8 = 0;
    try service.addTransformer(.{ .context = &ignored, .transform = Preserve.transform });

    try std.testing.expect(shouldTransformH2(&context, .request));
    try std.testing.expect(shouldTransformH2(&context, .response));
}

test "HTTP1 Claude SSE publishes provider turn completion after forwarding" {
    const FakeSession = @import("http/test_support.zig").FakeSession;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{test_claude_end_turn_event.len}) ++ "\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        test_claude_end_turn_event;
    var session: FakeSession = .{
        .child_input = "POST /v1/messages HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        .origin_input = response,
    };

    var fixture: TestServiceFixture = .{};
    try fixture.init(io, gpa);
    defer fixture.deinit();
    const service = fixture.service.?;

    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 11,
        .token = .{0x42} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    var tunnel_context: TunnelContext = .{
        .io = service.io,
        .pipeline = &service.pipeline,
        .telemetry = &service.telemetry,
        .credential = credential,
        .provider = .claude,
        .connection_id = 19,
        .protocol = .http11,
    };

    const parsed_request = http.relayHead(&session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
        .provider = tunnel_context.provider,
    }).?;
    const request: http.RequestHead = .{
        .classification = parsed_request.classification,
        .body = parsed_request.framing,
        .response_context = .normal,
    };
    tunnel_context.publish(httpRequestPhase(request.classification), 0);

    const parsed_response = http.relayHead(&session, .{
        .from = .origin,
        .to = .child,
        .is_response = true,
        .response_to_head = false,
    }).?;
    var observer: HttpResponseObserver = .init(
        &tunnel_context,
        shouldInspectHttpResponse(request, parsed_response),
    );
    defer observer.deinit();

    try std.testing.expect(http.relayBody(
        &session,
        .{ .from = .origin, .to = .child, .framing = parsed_response.framing },
        &observer,
    ));
    tunnel_context.status_code = parsed_response.message.status_code;
    tunnel_context.publish(httpResponsePhase(tunnel_context.status_code), 0);

    try expectTestObservations(service, &.{
        .{ .phase = .request_started, .protocol = .http11, .connection_id = 19, .stream_id = 0 },
        .{ .phase = .response_activity, .protocol = .http11, .connection_id = 19, .stream_id = 0 },
        .{ .phase = .provider_turn_completed, .protocol = .http11, .connection_id = 19, .stream_id = 0 },
        .{ .phase = .response_finished, .protocol = .http11, .connection_id = 19, .stream_id = 0 },
    });

    try std.testing.expectEqualStrings(session.child_input, session.originOutput());
    try std.testing.expectEqualStrings(response, session.childOutput());
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 0), service.metrics().claude_failure_observations);
}

test "HTTP2 final DATA publishes Claude completion before transport completion" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: TestServiceFixture = .{};
    try fixture.init(io, gpa);
    defer fixture.deinit();
    const service = fixture.service.?;

    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(13),
        .pane_generation = 17,
        .token = .{0x24} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    var tunnel_context: TunnelContext = .{
        .io = service.io,
        .pipeline = &service.pipeline,
        .telemetry = &service.telemetry,
        .credential = credential,
        .provider = .claude,
        .connection_id = 29,
        .protocol = .h2,
    };
    var responses = provider.ResponseStreams.init(gpa, .claude);
    defer responses.deinit();
    var observer: H2EventObserver = .{
        .context = &tunnel_context,
        .responses = &responses,
    };

    observer.emit(.{ .lifecycle = .{
        .phase = .request_started,
        .stream_id = 31,
        .status_code = 0,
    } });
    observer.emit(.{ .lifecycle = .{
        .phase = .response_activity,
        .stream_id = 31,
        .status_code = 200,
    } });
    observer.emit(.{ .response_body = .{
        .stream_id = 31,
        .status_code = 200,
        .sse_body = true,
        .bytes = test_claude_end_turn_event,
    } });
    observer.emit(.{ .lifecycle = .{
        .phase = .response_finished,
        .stream_id = 31,
        .status_code = 200,
    } });

    try expectTestObservations(service, &.{
        .{ .phase = .request_started, .protocol = .h2, .connection_id = 29, .stream_id = 31 },
        .{ .phase = .response_activity, .protocol = .h2, .connection_id = 29, .stream_id = 31 },
        .{ .phase = .provider_turn_completed, .protocol = .h2, .connection_id = 29, .stream_id = 31 },
        .{ .phase = .response_finished, .protocol = .h2, .connection_id = 29, .stream_id = 31 },
    });
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 1), service.metrics().claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 0), service.metrics().claude_failure_observations);
}

test "HTTP response metadata preserves final routing semantics" {
    const informational = semanticResponseHead(.{
        .message = .{ .status_code = 100, .informational = true },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.informational, informational.kind);
    try std.testing.expectEqual(http.ConnectionPolicy.keep_alive, informational.connection);

    const upgrade = semanticResponseHead(.{
        .message = .{ .status_code = 101, .upgrade = true },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.upgrade, upgrade.kind);

    const closing = semanticResponseHead(.{
        .message = .{ .status_code = 200, .closes = true },
        .framing = .until_close,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.final, closing.kind);
    try std.testing.expectEqual(http.ConnectionPolicy.close, closing.connection);
    try std.testing.expectEqual(http.BodyPlan.until_close, closing.body);
}

test "HTTP observations map request class and final status" {
    try std.testing.expectEqual(middleware.Phase.request_started, httpRequestPhase(.inference));
    try std.testing.expectEqual(middleware.Phase.auxiliary_request_started, httpRequestPhase(.auxiliary));

    inline for (.{ @as(u16, 200), 204, 399 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.response_finished, httpResponsePhase(status_code));
    }

    inline for (.{ @as(u16, 400), 429, 599 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.request_failed, httpResponsePhase(status_code));
    }
}

fn relayUpgrade(io: Io, session: *tls.Session, context: *TunnelContext) void {
    var outbound = io.concurrent(pumpUpgrade, .{ session, UpgradeRoute{ .from = .child, .to = .origin }, context }) catch return;
    pumpUpgrade(session, .{ .from = .origin, .to = .child }, context);
    outbound.await(io);
    context.publish(.response_finished, 0);
}

fn relayPassthrough(io: Io, child: net.Stream, origin: net.Stream) void {
    var outbound = io.concurrent(pumpPassthrough, .{ io, child, origin }) catch return;
    pumpPassthrough(io, origin, child);
    outbound.await(io);
}

fn pumpPassthrough(io: Io, source: net.Stream, destination: net.Stream) void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = source.reader(io, &read_buffer);
    var writer = destination.writer(io, &write_buffer);
    while (true) {
        const copied = reader.interface.stream(&writer.interface, .unlimited) catch break;
        writer.interface.flush() catch break;
        if (copied == 0) break;
    }
    destination.shutdown(io, .send) catch {};
}

fn pumpUpgrade(session: *tls.Session, route: UpgradeRoute, context: *TunnelContext) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (session.read(route.from, &buffer)) |len| {
        if (!session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        if (route.from == .origin) {
            context.publish(.response_activity, 0);
        }
    }

    session.halfClose(route.to);
}

fn readConnectHead(io: Io, stream: net.Stream, buffer: []u8) ?usize {
    var read_buffer: [8 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
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

fn echoOpaquePayload(io: Io, listener: *net.Server, expected: []const u8) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var payload: [256]u8 = undefined;
    for (payload[0..expected.len]) |*byte| byte.* = try reader.interface.takeByte();
    try std.testing.expectEqualStrings(expected, payload[0..expected.len]);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(payload[0..expected.len]);
    try writer.interface.flush();
}

fn rejectTlsHandshake(io: Io, listener: *net.Server) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);

    var write_buffer: [32]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(&.{ 0x16, 0x03, 0x03, 0xff, 0xff });
    try writer.interface.flush();
}

fn listenTestOrigin(io: Io) !Bound {
    var port: u16 = 49_152;
    while (port < 49_280) : (port += 1) {
        const address = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const listener = address.listen(io, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => |other| return other,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.TestOriginPortUnavailable;
}

test "passthrough CONNECT relays bytes with a saturated observation queue" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const payload = "not-a-tls-client-hello";
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(echoOpaquePayload, .{ io, &origin.listener, payload });
    defer origin_worker.cancel(io) catch {};

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
        .passthrough_hosts = &.{"localhost"},
    });
    defer service.destroy();
    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 12,
        .token = .{0x11} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    const observation: middleware.Event = .{
        .credential = credential,
        .provider = .codex,
        .phase = .response_activity,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    };
    for (0..event_capacity) |_| service.pipeline.publish(io, observation);
    service.pipeline.publish(io, observation);
    const observation_metrics = service.observations.metrics();

    try std.testing.expectEqual(
        @as(u64, event_capacity),
        observation_metrics.queued,
    );
    try std.testing.expectEqual(
        @as(u64, event_capacity),
        observation_metrics.high_water,
    );
    try std.testing.expectEqual(@as(u64, 1), observation_metrics.dropped);
    var worker = try io.concurrent(Service.run, .{service});
    defer worker.cancel(io) catch {};

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    const raw = "telar:7.12.11111111111111111111111111111111";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT localhost:{d} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{ origin.port, basic },
    );
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: ["HTTP/1.1 200 Connection Established\r\n\r\n".len]u8 = undefined;
    try reader.interface.readSliceAll(&response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Connection Established\r\n\r\n",
        &response,
    );

    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    var echoed: [payload.len]u8 = undefined;
    for (&echoed) |*byte| byte.* = try reader.interface.takeByte();
    try std.testing.expectEqualStrings(payload, &echoed);
    client.shutdown(io, .send) catch {};
    try origin_worker.await(io);
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().passthrough_connections,
    );
}

test "intercepted CONNECT publishes and counts an upstream TLS failure" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var origin = try listenTestOrigin(io);
    defer origin.listener.deinit(io);
    var origin_worker = try io.concurrent(rejectTlsHandshake, .{ io, &origin.listener });
    defer origin_worker.cancel(io) catch {};

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

    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(9),
        .pane_generation = 4,
        .token = .{0x22} ** identity.token_bytes,
    };
    try service.registerCredential(&credential);
    var worker = try io.concurrent(Service.run, .{service});
    defer worker.cancel(io) catch {};

    const proxy_address = try net.IpAddress.parse("127.0.0.1", service.port);
    const client = try proxy_address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    const raw = "telar:9.4.22222222222222222222222222222222";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT localhost:{d} HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{ origin.port, basic },
    );
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [512]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var response: ["HTTP/1.1 200 Connection Established\r\n\r\n".len]u8 = undefined;
    try reader.interface.readSliceAll(&response);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Connection Established\r\n\r\n",
        &response,
    );

    try writer.interface.writeAll("not-a-tls-client-hello");
    try writer.interface.flush();
    try origin_worker.await(io);

    var event = try service.receive(io);
    defer std.crypto.secureZero(u8, &event.credential.token);
    try std.testing.expectEqual(middleware.Phase.request_failed, event.phase);
    try std.testing.expectEqual(middleware.Protocol.http11, event.protocol);
    try std.testing.expectEqual(@as(u32, 0), event.stream_id);
    try std.testing.expect(std.meta.eql(credential, event.credential));
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().tls_upstream_handshake_failures,
    );
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_context_failures);
    try std.testing.expectEqual(
        @as(u64, 0),
        service.metrics().tls_downstream_handshake_failures,
    );
    try std.testing.expectEqual(@as(u64, 0), service.metrics().tls_mint_failures);
}

test "receive discards observations queued before pane revocation" {
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

    const current: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .token = .{0x5a} ** identity.token_bytes,
    };
    const next: identity.Credential = .{
        .pane_id = current.pane_id,
        .pane_generation = 3,
        .token = .{0x6b} ** identity.token_bytes,
    };
    try service.registerCredential(&current);
    service.pipeline.publish(io, .{
        .credential = current,
        .provider = .codex,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 1,
        .observed_at_ms = 1,
    });
    service.unregisterPane(current.pane_id, current.pane_generation);
    try service.registerCredential(&next);
    service.pipeline.publish(io, .{
        .credential = next,
        .provider = .codex,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = 2,
        .observed_at_ms = 2,
    });

    var received = try service.receive(io);
    defer std.crypto.secureZero(u8, &received.credential.token);
    try std.testing.expect(std.meta.eql(next, received.credential));
    try std.testing.expectEqual(@as(u64, 0), service.observations.metrics().queued);
}

test "loopback service maps CONNECT authentication and target rejections" {
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
    try std.testing.expect(std.mem.indexOf(
        u8,
        response[0..response_len],
        "Connection: close\r\n",
    ) != null);
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().invalid_authorization_rejections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        service.metrics().unknown_credential_rejections,
    );

    const unknown_client = try address.connect(io, .{ .mode = .stream });
    defer unknown_client.close(io);
    var unknown_write_buffer: [512]u8 = undefined;
    var unknown_writer = unknown_client.writer(io, &unknown_write_buffer);
    const raw = "telar:7.12.00112233445566778899aabbccddeeff";
    var encoded: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const basic = std.base64.standard.Encoder.encode(&encoded, raw);
    var request_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "CONNECT api.openai.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{basic},
    );
    try unknown_writer.interface.writeAll(request);
    try unknown_writer.interface.flush();
    var unknown_read_buffer: [512]u8 = undefined;
    var unknown_reader = unknown_client.reader(io, &unknown_read_buffer);
    var unknown_response: [512]u8 = undefined;
    const unknown_response_len = try unknown_reader.interface.readSliceShort(&unknown_response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        unknown_response[0..unknown_response_len],
        "HTTP/1.1 407 Proxy Authentication Required\r\n",
    ));
    try std.testing.expectEqual(
        @as(u64, 1),
        service.metrics().unknown_credential_rejections,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        service.metrics().rejected_connections,
    );

    var credential = identity.parseProxyAuthorization(request).?;
    defer std.crypto.secureZero(u8, &credential.token);
    try service.registerCredential(&credential);
    const invalid_target_client = try address.connect(io, .{ .mode = .stream });
    defer invalid_target_client.close(io);
    var invalid_target_write_buffer: [512]u8 = undefined;
    var invalid_target_writer = invalid_target_client.writer(io, &invalid_target_write_buffer);
    var invalid_target_request_buffer: [256]u8 = undefined;
    const invalid_target_request = try std.fmt.bufPrint(
        &invalid_target_request_buffer,
        "GET / HTTP/1.1\r\nProxy-Authorization: Basic {s}\r\n\r\n",
        .{basic},
    );
    try invalid_target_writer.interface.writeAll(invalid_target_request);
    try invalid_target_writer.interface.flush();
    var invalid_target_read_buffer: [256]u8 = undefined;
    var invalid_target_reader = invalid_target_client.reader(io, &invalid_target_read_buffer);
    var invalid_target_response: [256]u8 = undefined;
    const invalid_target_response_len = try invalid_target_reader.interface.readSliceShort(&invalid_target_response);
    try std.testing.expect(std.mem.startsWith(
        u8,
        invalid_target_response[0..invalid_target_response_len],
        "HTTP/1.1 400 Bad Request\r\n",
    ));
    try std.testing.expectEqual(
        @as(u64, 2),
        service.metrics().rejected_connections,
    );
}
