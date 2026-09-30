const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const std = @import("std");
const service_support = @import("service_support.zig");
const Worker = @import("Worker.zig");
const Result = @import("Result.zig");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = owned.Exchange;
const ExchangeIdentity = @import("ExchangeIdentity.zig");
const Frame = @import("Frame.zig");
const protocol = @import("protocol.zig");
const TapLimitCounts = @import("TapLimitCounts.zig");
const Service = @This();

gpa: std.mem.Allocator,
io: std.Io,
workers: [service_support.max_workers]Worker = undefined,
worker_count: u8 = 0,
results: std.Io.Queue(*Result) = undefined,
result_storage: [service_support.queue_depth]*Result = undefined,
next_event_id: std.atomic.Value(u64) = .init(1),
/// Bytes of frames every worker queue holds, within `max_queued_bytes`.
queued_bytes: std.atomic.Value(usize) = .init(0),
/// Frames dropped because they did not fit `max_queued_bytes`.
dropped_bytes: std.atomic.Value(u64) = .init(0),

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
        const size = service_support.capturedBytes(captured) + protocol.overhead_bytes;
        if (!self.charge(size)) {
            _ = self.dropped_bytes.fetchAdd(1, .monotonic);
            continue;
        }

        const frame = self.encodeFrame(captured, identity, size) catch {
            _ = self.queued_bytes.fetchSub(size, .monotonic);
            continue;
        };
        worker.submit(self.io, frame);
    }
}

/// Whether any tap worker receives exchanges.
///
/// ```zig
/// if (service.listening()) decode(half);
/// ```
pub fn listening(self: *const Service) bool {
    return self.worker_count != 0;
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
            .notification => .notifications,
        };
        try service_support.requireCapability(spec, capability);
    }
}

/// Counts what the tap reached: frames dropped at a full queue or past the
/// queued-bytes budget, replies past their timeout, and disabled workers.
///
/// ```zig
/// const counts = service.limitCounts();
/// ```
pub fn limitCounts(self: *const Service) TapLimitCounts {
    var counts: TapLimitCounts = .{ .dropped_bytes = self.dropped_bytes.load(.monotonic) };
    for (self.workers[0..self.worker_count]) |*worker| {
        counts.dropped_queue += worker.dropped.load(.monotonic);
        counts.timeouts += worker.timeouts.load(.monotonic);
        counts.disabled += @intFromBool(worker.disabled.load(.monotonic));
    }

    return counts;
}

/// Encodes one exchange into a frame of `size` bytes already charged to the
/// queued-bytes budget; the frame releases them when it is freed.
fn encodeFrame(self: *Service, captured: *const Exchange, identity: ExchangeIdentity, size: usize) !*Frame {
    const bytes = try self.gpa.alloc(u8, size);
    errdefer self.gpa.free(bytes);
    const payload = try protocol.encodeExchange(bytes, identity, captured);
    const frame = try self.gpa.create(Frame);
    frame.* = .{
        .gpa = self.gpa,
        .event_id = identity.id,
        .storage = bytes,
        .len = payload.len,
        .budget = &self.queued_bytes,
    };
    return frame;
}

/// Charges `size` bytes to the queued-bytes budget when they fit.
fn charge(self: *Service, size: usize) bool {
    var current = self.queued_bytes.load(.monotonic);
    while (size <= service_support.max_queued_bytes -| current) {
        current = self.queued_bytes.cmpxchgWeak(current, current + size, .monotonic, .monotonic) orelse return true;
    }

    return false;
}

const InitOptions = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    specs: []const ServiceSpec,
};

test "the queued-bytes budget refuses a frame past it and a freed frame returns its bytes" {
    var service: Service = undefined;
    service.queued_bytes = .init(0);

    try std.testing.expect(service.charge(service_support.max_queued_bytes - 1));
    try std.testing.expect(!service.charge(2));
    try std.testing.expect(service.charge(1));
    try std.testing.expect(!service.charge(1));

    const frame = try std.testing.allocator.create(Frame);
    frame.* = .{
        .gpa = std.testing.allocator,
        .event_id = 1,
        .storage = try std.testing.allocator.alloc(u8, 1),
        .len = 1,
        .budget = &service.queued_bytes,
    };
    frame.deinit();

    try std.testing.expectEqual(@as(usize, service_support.max_queued_bytes - 1), service.queued_bytes.load(.monotonic));
    try std.testing.expect(service.charge(1));
}
