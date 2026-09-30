const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const std = @import("std");
const service_support = @import("service_support.zig");
const Worker = @import("Worker.zig");
const Result = @import("Result.zig");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = owned.Exchange;
const SharedExchange = @import("SharedExchange.zig");
const TapBudget = @import("TapBudget.zig");
const TapLimitCounts = @import("TapLimitCounts.zig");
const Service = @This();

gpa: std.mem.Allocator,
io: std.Io,
workers: [service_support.max_workers]Worker = undefined,
worker_count: u8 = 0,
results: std.Io.Queue(*Result) = undefined,
result_storage: [service_support.queue_depth]*Result = undefined,
next_event_id: std.atomic.Value(u64) = .init(1),
/// Bytes of queued exchanges and frames being sent, within `max_held_bytes`.
budget: TapBudget = .{
    .max_bytes = service_support.max_held_bytes,
},

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

/// Hands one completed exchange to every tap worker's bounded queue, shared
/// rather than copied: each worker encodes its frame on its own thread, so
/// the event loop only moves pointers. An exchange past the queued-bytes
/// budget is dropped and counted.
///
/// ```zig
/// service.submit(&exchange);
/// ```
pub fn submit(self: *Service, captured: *Exchange) void {
    defer captured.deinit();
    if (self.worker_count == 0) {
        return;
    }

    const size = service_support.capturedBytes(captured);
    if (!self.budget.charge(size)) {
        return;
    }

    const shared = SharedExchange.create(self.gpa, captured, .{
        .event_id = self.next_event_id.fetchAdd(1, .monotonic),
        .charged = size,
        .budget = &self.budget,
        .holders = self.worker_count,
    }) catch {
        self.budget.release(size);
        return;
    };

    for (self.workers[0..self.worker_count]) |*worker| {
        worker.submit(self.io, shared);
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
    var counts: TapLimitCounts = .{
        .dropped_bytes = self.budget.dropped.load(.monotonic),
    };
    for (self.workers[0..self.worker_count]) |*worker| {
        counts.dropped_queue += worker.dropped.load(.monotonic);
        counts.timeouts += worker.timeouts.load(.monotonic);
        counts.disabled += @intFromBool(worker.disabled.load(.monotonic));
    }

    return counts;
}

const InitOptions = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    specs: []const ServiceSpec,
};

test "the last worker to release a shared exchange returns its bytes" {
    var budget: TapBudget = .{
        .max_bytes = 8,
    };
    try std.testing.expect(budget.charge(8));

    var exchange: Exchange = .{};
    const shared = try SharedExchange.create(std.testing.allocator, &exchange, .{
        .event_id = 1,
        .charged = 8,
        .budget = &budget,
        .holders = 2,
    });
    shared.release();
    try std.testing.expect(!budget.charge(1));

    shared.release();
    try std.testing.expect(budget.charge(8));
}
