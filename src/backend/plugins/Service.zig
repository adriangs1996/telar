const std = @import("std");
const service_support = @import("service_support.zig");
const Worker = @import("Worker.zig");
const ResultType = @import("Result.zig");
const InitOptions = @import("InitOptions.zig");
const Exchange = @import("../proxy/capture/Exchange.zig");
const ExchangeIdentityType = @import("ExchangeIdentity.zig");
const CapabilityType = @import("telar-core").Capability;
const Frame = @import("Frame.zig");
const protocol = @import("protocol.zig");
const Service = @This();

gpa: std.mem.Allocator,
io: std.Io,
workers: [service_support.max_workers]Worker = undefined,
worker_count: u8 = 0,
results: std.Io.Queue(*ResultType) = undefined,
result_storage: [service_support.queue_depth]*ResultType = undefined,
next_event_id: std.atomic.Value(u64) = .init(1),

/// Starts one actor for every configured and trusted tap plugin.
///
/// ```zig
/// var service: Service = undefined;
/// try service.init(.{ .io = io, .gpa = gpa, .specs = specs });
/// ```
pub fn init(service: *Service, options: InitOptions) !void {
    if (options.specs.len > service_support.max_workers) {
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
        var pending: [1]*ResultType = undefined;
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
pub fn submit(service: *Service, captured: *Exchange) void {
    defer captured.deinit();
    if (service.worker_count == 0) {
        return;
    }
    const event_id = service.next_event_id.fetchAdd(1, .monotonic);
    for (service.workers[0..service.worker_count]) |*worker| {
        const identity: ExchangeIdentityType = .{ .id = event_id, .generation = worker.spec.generation };
        const frame = service.encodeFrame(captured, identity) catch continue;
        worker.submit(service.io, frame);
    }
}

/// Waits for the next validated worker protocol result.
///
/// ```zig
/// const result = try service.receive(io);
/// ```
pub fn receive(service: *Service, io: std.Io) anyerror!*ResultType {
    return service.results.getOne(io);
}

/// Validates exact plugin identity, generation, digest, and effect grants.
///
/// ```zig
/// try service.authorize(result);
/// ```
pub fn authorize(service: *const Service, result: *const ResultType) !void {
    if (result.package_index >= service.worker_count) {
        return error.PluginNotConfigured;
    }
    const spec = &service.workers[result.package_index].spec;
    if (spec.generation != result.generation or spec.plugin_id != result.plugin_id or !std.mem.eql(u8, &spec.digest, &result.digest)) {
        return error.StaleTapWorker;
    }
    try service_support.requireCapability(spec, .proxy_tap);
    for (result.batch.slice()) |effect| {
        const capability: CapabilityType = switch (effect) {
            .record_command => .history_write,
            .notification => .notifications,
            .agent_evidence => .proxy_tap,
        };
        try service_support.requireCapability(spec, capability);
    }
}

fn encodeFrame(service: *Service, captured: *const Exchange, identity: ExchangeIdentityType) !*Frame {
    const size = service_support.capturedBytes(captured) + protocol.overhead_bytes;
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
