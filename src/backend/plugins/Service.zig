const core = @import("telar-core");
const std = @import("std");
const service_support = @import("service_support.zig");
const Worker = @import("Worker.zig");
const Result = @import("Result.zig");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = @import("../proxy/capture/Exchange.zig");
const ExchangeIdentity = @import("ExchangeIdentity.zig");
const Frame = @import("Frame.zig");
const protocol = @import("protocol.zig");
const Service = @This();

gpa: std.mem.Allocator,
io: std.Io,
workers: [service_support.max_workers]Worker = undefined,
worker_count: u8 = 0,
results: std.Io.Queue(*Result) = undefined,
result_storage: [service_support.queue_depth]*Result = undefined,
next_event_id: std.atomic.Value(u64) = .init(1),

/// Starts one actor for every configured and trusted tap plugin.
///
/// ```zig
/// var service: Service = undefined;
/// try service.init(.{ .io = io, .gpa = gpa, .specs = specs });
/// ```
pub fn init(self: *Service, options: InitOptions) !void {
    if (options.specs.len > service_support.max_workers) {
        return error.TooManyTapPlugins;
    }
    self.* = .{ .gpa = options.gpa, .io = options.io };
    self.results = .init(&self.result_storage);
    errdefer {
        for (self.workers[0..self.worker_count]) |*worker| worker.stop(options.io);
    }
    for (options.specs, 0..) |spec, index| {
        self.workers[index].init(.{ .gpa = options.gpa, .spec = spec, .results = &self.results });
        try self.workers[index].start(options.io);
        self.worker_count += 1;
    }
}

/// Stops workers, kills their descendants, and frees queued frames.
///
/// ```zig
/// service.deinit();
/// ```
pub fn deinit(self: *Service) void {
    for (self.workers[0..self.worker_count]) |*worker| worker.stop(self.io);
    self.results.close(self.io);
    while (true) {
        var pending: [1]*Result = undefined;
        const count = self.results.getUncancelable(self.io, &pending, 0) catch break;
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
pub fn submit(self: *Service, captured: *Exchange) void {
    defer captured.deinit();
    if (self.worker_count == 0) {
        return;
    }
    const event_id = self.next_event_id.fetchAdd(1, .monotonic);
    for (self.workers[0..self.worker_count]) |*worker| {
        const identity: ExchangeIdentity = .{ .id = event_id, .generation = worker.spec.generation };
        const frame = self.encodeFrame(captured, identity) catch continue;
        worker.submit(self.io, frame);
    }
}

/// Waits for the next validated worker protocol result.
///
/// ```zig
/// const result = try service.receive(io);
/// ```
pub fn receive(self: *Service, io: std.Io) anyerror!*Result {
    return self.results.getOne(io);
}

/// Validates exact plugin identity, generation, digest, and effect grants.
///
/// ```zig
/// try service.authorize(result);
/// ```
pub fn authorize(self: *const Service, result: *const Result) !void {
    if (result.package_index >= self.worker_count) {
        return error.PluginNotConfigured;
    }
    const spec = &self.workers[result.package_index].spec;
    if (spec.generation != result.generation or spec.plugin_id != result.plugin_id or !std.mem.eql(u8, &spec.digest, &result.digest)) {
        return error.StaleTapWorker;
    }
    try service_support.requireCapability(spec, .proxy_tap);
    for (result.batch.slice()) |effect| {
        const capability: core.Capability = switch (effect) {
            .record_command => .history_write,
            .notification => .notifications,
            .agent_evidence => .proxy_tap,
        };
        try service_support.requireCapability(spec, capability);
    }
}

fn encodeFrame(self: *Service, captured: *const Exchange, identity: ExchangeIdentity) !*Frame {
    const size = service_support.capturedBytes(captured) + protocol.overhead_bytes;
    const bytes = try self.gpa.alloc(u8, size);
    errdefer self.gpa.free(bytes);
    const payload = try protocol.encodeExchange(bytes, identity, captured);
    const representative = captured.request orelse captured.response orelse return error.EmptyCapture;
    const frame = try self.gpa.create(Frame);
    frame.* = .{
        .gpa = self.gpa,
        .event_id = identity.id,
        .pane = representative.pane.id,
        .pane_generation = representative.pane.generation,
        .storage = bytes,
        .len = payload.len,
    };
    return frame;
}

const InitOptions = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    specs: []const ServiceSpec,
};
