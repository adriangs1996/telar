const Service = @This();
const std = @import("std");
const source_namespace = @import("service_support.zig");
const Worker = @import("Worker.zig");
const effects = @import("effects.zig");
const InitOptions = @import("InitOptions.zig");
const proxy = @import("../proxy/root.zig");
const protocol = @import("protocol.zig");
const core = @import("telar-core");
const Frame = @import("Frame.zig");
gpa: std.mem.Allocator,
io: source_namespace.Io,
workers: [source_namespace.max_workers]Worker = undefined,
worker_count: u8 = 0,
results: source_namespace.Io.Queue(*effects.Result) = undefined,
result_storage: [source_namespace.queue_depth]*effects.Result = undefined,
next_event_id: std.atomic.Value(u64) = .init(1),

/// Starts one actor for every configured and trusted tap plugin.
///
/// ```zig
/// var service: Service = undefined;
/// try service.init(.{ .io = io, .gpa = gpa, .specs = specs });
/// ```
pub fn init(service: *Service, options: InitOptions) !void {
    if (options.specs.len > source_namespace.max_workers) {
        return error.TooManyTapPlugins;
    }
    service.* = .{ .gpa = options.gpa, .io = options.io };
    service.results = .init(&service.result_storage);
    errdefer {
        for (service.workers[0..service.worker_count]) |*worker| worker.stop(options.io);
    }
    for (options.specs, 0..) |spec, index| {
        service.workers[index].init(.{ .gpa = options.gpa, .spec = spec, .results = &service.results });
        try service.workers[index].start(options.io);
        service.worker_count += 1;
    }
}

/// Stops workers, kills their descendants, and frees queued frames.
///
/// ```zig
/// service.deinit();
/// ```
pub fn deinit(service: *Service) void {
    for (service.workers[0..service.worker_count]) |*worker| worker.stop(service.io);
    service.results.close(service.io);
    while (true) {
        var pending: [1]*effects.Result = undefined;
        const count = service.results.getUncancelable(service.io, &pending, 0) catch break;
        if (count == 0) {
            break;
        }
        pending[0].deinit();
    }
}

/// Fans one completed exchange out to bounded per-plugin queues and frees it.
///
/// ```zig
/// service.submit(&exchange);
/// ```
pub fn submit(service: *Service, captured: *proxy.CaptureExchange) void {
    defer captured.deinit();
    if (service.worker_count == 0) {
        return;
    }
    const event_id = service.next_event_id.fetchAdd(1, .monotonic);
    for (service.workers[0..service.worker_count]) |*worker| {
        const identity: protocol.ExchangeIdentity = .{ .id = event_id, .generation = worker.spec.generation };
        const frame = service.encodeFrame(captured, identity) catch continue;
        worker.submit(service.io, frame);
    }
}

/// Waits for the next validated worker protocol result.
///
/// ```zig
/// const result = try service.receive(io);
/// ```
pub fn receive(service: *Service, io: source_namespace.Io) anyerror!*effects.Result {
    return service.results.getOne(io);
}

/// Validates exact plugin identity, generation, digest, and effect grants.
///
/// ```zig
/// try service.authorize(result);
/// ```
pub fn authorize(service: *const Service, result: *const effects.Result) !void {
    if (result.package_index >= service.worker_count) {
        return error.PluginNotConfigured;
    }
    const spec = &service.workers[result.package_index].spec;
    if (spec.generation != result.generation or spec.plugin_id != result.plugin_id or !std.mem.eql(u8, &spec.digest, &result.digest)) {
        return error.StaleTapWorker;
    }
    try source_namespace.requireCapability(spec, .proxy_tap);
    for (result.batch.slice()) |effect| {
        const capability: core.plugin.Capability = switch (effect) {
            .record_command => .history_write,
            .notification => .notifications,
            .agent_evidence => .proxy_tap,
        };
        try source_namespace.requireCapability(spec, capability);
    }
}

fn encodeFrame(service: *Service, captured: *const proxy.CaptureExchange, identity: protocol.ExchangeIdentity) !*Frame {
    const size = source_namespace.capturedBytes(captured) + protocol.overhead_bytes;
    const bytes = try service.gpa.alloc(u8, size);
    errdefer service.gpa.free(bytes);
    const payload = try protocol.encodeExchange(bytes, identity, captured);
    const representative = captured.request orelse captured.response orelse return error.EmptyCapture;
    const frame = try service.gpa.create(Frame);
    frame.* = .{
        .gpa = service.gpa,
        .event_id = identity.id,
        .pane = representative.pane.id,
        .pane_generation = representative.pane.generation,
        .storage = bytes,
        .len = payload.len,
    };
    return frame;
}
