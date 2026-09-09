//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const std = @import("std");
const core = @import("telar-core");
const effects = @import("effects.zig");
const protocol = @import("protocol.zig");
const proxy = @import("../proxy/root.zig");
const session_mod = @import("session.zig");

const Io = std.Io;
const Session = session_mod.Session;
pub const max_workers = 16;
pub const queue_depth = 64;
const restart_limit = 5;
const restart_window_ms = 10 * 60 * 1000;

pub const Spec = struct {
    package_index: u8,
    plugin_id: u64,
    digest: core.plugin.Digest,
    generation: u64,
    entry_storage: [std.fs.max_path_bytes]u8 = undefined,
    entry_len: u16,
    declared: core.plugin.CapabilitySet,
    granted: core.plugin.CapabilitySet,

    pub fn init(package_index: u8, generation: u64, package: Package) !Spec {
        if (package.entry.len > std.fs.max_path_bytes) {
            return error.PluginPathTooLong;
        }
        var spec: Spec = .{
            .package_index = package_index,
            .plugin_id = core.plugin.stableId(package.id),
            .digest = package.digest,
            .generation = generation,
            .entry_len = @intCast(package.entry.len),
            .declared = package.declared,
            .granted = package.granted,
        };
        @memcpy(spec.entry_storage[0..package.entry.len], package.entry);
        return spec;
    }

    pub fn entry(spec: *const Spec) []const u8 {
        return spec.entry_storage[0..spec.entry_len];
    }

    pub fn allows(spec: *const Spec, capability: core.plugin.Capability) bool {
        return spec.declared.contains(capability) and spec.granted.contains(capability);
    }
};

pub const Package = struct {
    id: []const u8,
    entry: []const u8,
    digest: core.plugin.Digest,
    declared: core.plugin.CapabilitySet,
    granted: core.plugin.CapabilitySet,
};

const Frame = struct {
    gpa: std.mem.Allocator,
    event_id: u64,
    pane: core.schema.PaneId,
    pane_generation: u64,
    storage: []u8,
    len: usize,

    fn bytes(frame: *const Frame) []u8 {
        return frame.storage[0..frame.len];
    }

    fn deinit(frame: *Frame) void {
        const gpa = frame.gpa;
        std.crypto.secureZero(u8, frame.storage);
        gpa.free(frame.storage);
        gpa.destroy(frame);
    }
};

const Worker = struct {
    const WorkerInitOptions = struct {
        gpa: std.mem.Allocator,
        spec: Spec,
        results: *Io.Queue(*effects.Result),
    };

    gpa: std.mem.Allocator,
    spec: Spec,
    results: *Io.Queue(*effects.Result),
    requests: Io.Queue(*Frame) = undefined,
    request_storage: [queue_depth]*Frame = undefined,
    session: ?*Session = null,
    future: ?Io.Future(anyerror!void) = null,
    restarts: [restart_limit]i64 = .{0} ** restart_limit,
    restart_count: u8 = 0,
    disabled: bool = false,
    dropped: std.atomic.Value(u64) = .init(0),

    fn init(worker: *Worker, options: WorkerInitOptions) void {
        worker.* = .{ .gpa = options.gpa, .spec = options.spec, .results = options.results };
        worker.requests = .init(&worker.request_storage);
    }

    fn start(worker: *Worker, io: Io) !void {
        worker.future = try io.concurrent(run, .{ worker, io });
    }

    fn stop(worker: *Worker, io: Io) void {
        worker.requests.close(io);
        if (worker.future) |*future| {
            _ = future.await(io) catch {};
            worker.future = null;
        }
        worker.closeSession();
        while (true) {
            var pending: [1]*Frame = undefined;
            const count = worker.requests.getUncancelable(io, &pending, 0) catch break;
            if (count == 0) {
                break;
            }
            pending[0].deinit();
        }
    }

    fn submit(worker: *Worker, io: Io, frame: *Frame) void {
        if (worker.disabled) {
            frame.deinit();
            return;
        }

        if ((worker.requests.put(io, &.{frame}, 0) catch 0) == 1) {
            return;
        }
        var oldest: [1]*Frame = undefined;
        if ((worker.requests.getUncancelable(io, &oldest, 0) catch 0) == 1) {
            oldest[0].deinit();
            _ = worker.dropped.fetchAdd(1, .monotonic);
        }
        if ((worker.requests.put(io, &.{frame}, 0) catch 0) != 1) {
            frame.deinit();
            _ = worker.dropped.fetchAdd(1, .monotonic);
        }
    }

    fn run(worker: *Worker, io: Io) anyerror!void {
        while (true) {
            const frame = worker.requests.getOne(io) catch return;
            defer frame.deinit();
            if (worker.disabled) {
                continue;
            }
            const session = worker.ensureSession(io) catch {
                worker.recordRestart(io);
                continue;
            };
            const result = session.exchange(.{
                .package_index = worker.spec.package_index,
                .plugin_id = worker.spec.plugin_id,
                .digest = worker.spec.digest,
                .generation = worker.spec.generation,
            }, .{
                .event_id = frame.event_id,
                .bytes = frame.bytes(),
                .pane = frame.pane,
                .pane_generation = frame.pane_generation,
            }) catch |err| {
                if (err != error.WorkerEventFailed) {
                    worker.closeSession();
                    worker.recordRestart(io);
                }
                continue;
            };
            if ((worker.results.put(io, &.{result}, 0) catch 0) != 1) {
                result.deinit();
            }
        }
    }

    fn ensureSession(worker: *Worker, io: Io) !*Session {
        if (worker.session) |session| {
            return session;
        }
        worker.session = try Session.open(io, worker.gpa, .{ .entry = worker.spec.entry(), .timeout_ms = 200 });
        return worker.session.?;
    }

    fn closeSession(worker: *Worker) void {
        const session = worker.session orelse return;
        worker.session = null;
        session.close();
    }

    fn recordRestart(worker: *Worker, io: Io) void {
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (worker.restart_count < restart_limit) {
            worker.restarts[worker.restart_count] = now_ms;
            worker.restart_count += 1;
            if (worker.restart_count == restart_limit and now_ms - worker.restarts[0] <= restart_window_ms) {
                worker.disabled = true;
            }
            return;
        }
        if (now_ms - worker.restarts[0] <= restart_window_ms) {
            worker.disabled = true;
            return;
        }
        std.mem.copyForwards(i64, worker.restarts[0 .. restart_limit - 1], worker.restarts[1..]);
        worker.restarts[restart_limit - 1] = now_ms;
    }
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    io: Io,
    workers: [max_workers]Worker = undefined,
    worker_count: u8 = 0,
    results: Io.Queue(*effects.Result) = undefined,
    result_storage: [queue_depth]*effects.Result = undefined,
    next_event_id: std.atomic.Value(u64) = .init(1),
    /// Completed exchanges waiting to be encoded, owned by the encoder actor
    /// so the submitting loop never copies exchange bytes itself.
    exchanges: Io.Queue(proxy.CaptureExchange) = undefined,
    exchange_storage: [queue_depth]proxy.CaptureExchange = undefined,
    encoder: ?Io.Future(anyerror!void) = null,
    dropped_exchanges: std.atomic.Value(u64) = .init(0),

    /// Starts one actor for every configured and trusted tap plugin.
    ///
    /// ```zig
    /// var service: Service = undefined;
    /// try service.init(.{ .io = io, .gpa = gpa, .specs = specs });
    /// ```
    pub fn init(service: *Service, options: InitOptions) !void {
        if (options.specs.len > max_workers) {
            return error.TooManyTapPlugins;
        }
        service.* = .{ .gpa = options.gpa, .io = options.io };
        service.results = .init(&service.result_storage);
        service.exchanges = .init(&service.exchange_storage);
        errdefer {
            for (service.workers[0..service.worker_count]) |*worker| worker.stop(options.io);
        }
        for (options.specs, 0..) |spec, index| {
            service.workers[index].init(.{ .gpa = options.gpa, .spec = spec, .results = &service.results });
            try service.workers[index].start(options.io);
            service.worker_count += 1;
        }
        if (service.worker_count != 0) {
            service.encoder = try options.io.concurrent(encodeExchanges, .{ service, options.io });
        }
    }

    /// Stops workers, kills their descendants, and frees queued frames.
    ///
    /// ```zig
    /// service.deinit();
    /// ```
    pub fn deinit(service: *Service) void {
        service.stopEncoder();
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

    /// Hands one completed exchange to the encoder actor, taking ownership of
    /// its halves. The caller's loop does no encoding; a full queue drops the
    /// newest exchange and counts it.
    ///
    /// ```zig
    /// service.submit(&exchange);
    /// ```
    pub fn submit(service: *Service, captured: *proxy.CaptureExchange) void {
        if (service.worker_count == 0 or service.encoder == null) {
            captured.deinit();
            return;
        }

        const owned = captured.*;
        captured.* = .{};
        if ((service.exchanges.put(service.io, &.{owned}, 0) catch 0) == 1) {
            return;
        }

        var rejected = owned;
        rejected.deinit();
        _ = service.dropped_exchanges.fetchAdd(1, .monotonic);
    }

    /// Exchanges the loop could not hand to the encoder because its queue
    /// was full. Example: `const lost = service.droppedExchanges();`.
    pub fn droppedExchanges(service: *const Service) u64 {
        return service.dropped_exchanges.load(.monotonic);
    }

    fn encodeExchanges(service: *Service, io: Io) anyerror!void {
        while (true) {
            var captured = service.exchanges.getOne(io) catch return;
            defer captured.deinit();
            service.fanOut(&captured);
        }
    }

    /// Encodes one exchange once per worker and queues each frame.
    fn fanOut(service: *Service, captured: *const proxy.CaptureExchange) void {
        const event_id = service.next_event_id.fetchAdd(1, .monotonic);
        for (service.workers[0..service.worker_count]) |*worker| {
            const identity: protocol.ExchangeIdentity = .{ .id = event_id, .generation = worker.spec.generation };
            const frame = service.encodeFrame(captured, identity) catch continue;
            worker.submit(service.io, frame);
        }
    }

    fn stopEncoder(service: *Service) void {
        service.exchanges.close(service.io);
        if (service.encoder) |*future| {
            _ = future.await(service.io) catch {};
            service.encoder = null;
        }
        while (true) {
            var pending: [1]proxy.CaptureExchange = undefined;
            const count = service.exchanges.getUncancelable(service.io, &pending, 0) catch break;
            if (count == 0) {
                break;
            }
            pending[0].deinit();
        }
    }

    /// Waits for the next validated worker protocol result.
    ///
    /// ```zig
    /// const result = try service.receive(io);
    /// ```
    pub fn receive(service: *Service, io: Io) anyerror!*effects.Result {
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
        try requireCapability(spec, .proxy_tap);
        for (result.batch.slice()) |effect| {
            const capability: core.plugin.Capability = switch (effect) {
                .record_command => .history_write,
                .notification => .notifications,
                .agent_evidence => .proxy_tap,
            };
            try requireCapability(spec, capability);
        }
    }

    fn encodeFrame(service: *Service, captured: *const proxy.CaptureExchange, identity: protocol.ExchangeIdentity) !*Frame {
        const size = capturedBytes(captured) + protocol.overhead_bytes;
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
};

fn requireCapability(spec: *const Spec, capability: core.plugin.Capability) !void {
    if (!spec.declared.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    if (!spec.granted.contains(capability)) {
        return error.CapabilityNotGranted;
    }
}

pub const InitOptions = struct {
    io: Io,
    gpa: std.mem.Allocator,
    specs: []const Spec,
};

fn capturedBytes(captured: *const proxy.CaptureExchange) usize {
    var total: usize = 0;
    inline for (.{ captured.request, captured.response }) |optional| {
        if (optional) |half| {
            total +|= half.head.len +| half.body.len;
        }
    }
    return total;
}

test "effect authorization checks exact identity, declaration and grant" {
    var declared = core.plugin.CapabilitySet.initEmpty();
    declared.insert(.proxy_tap);
    declared.insert(.history_write);
    var granted = core.plugin.CapabilitySet.initEmpty();
    granted.insert(.proxy_tap);
    const digest = [_]u8{0x5a} ** 32;
    const spec = try Spec.init(0, 7, .{
        .id = "tap.test",
        .entry = "/tmp/main.lua",
        .digest = digest,
        .declared = declared,
        .granted = granted,
    });
    var service: Service = undefined;
    service.worker_count = 1;
    service.workers[0].spec = spec;
    var storage: [1]u8 = .{0};
    var result: effects.Result = .{
        .gpa = std.testing.allocator,
        .package_index = 0,
        .plugin_id = core.plugin.stableId("tap.test"),
        .digest = digest,
        .generation = 7,
        .event_id = 1,
        .pane = @enumFromInt(3),
        .pane_generation = 4,
        .storage = &storage,
        .batch = .{ .len = 1 },
    };
    result.batch.items[0] = .{ .record_command = .{
        .command = "pwd",
        .cwd = "/tmp",
        .provider = "test",
        .tool_call_id = "",
        .session = null,
        .exit_code = 0,
        .started_at_ms = 1,
        .duration_ms = 2,
        .redact = true,
    } };

    try std.testing.expectError(error.CapabilityNotGranted, service.authorize(&result));
    service.workers[0].spec.granted.insert(.history_write);
    try service.authorize(&result);
    result.batch.items[0] = .{ .notification = .{ .level = .info, .duration_ms = 1000, .title = "tap", .message = "done" } };
    try std.testing.expectError(error.CapabilityNotDeclared, service.authorize(&result));
    result.digest[0] ^= 0xff;
    try std.testing.expectError(error.StaleTapWorker, service.authorize(&result));
}

test "worker queue drops the oldest frame when full" {
    const io = std.testing.io;
    var result_storage: [1]*effects.Result = undefined;
    var results: Io.Queue(*effects.Result) = .init(&result_storage);
    var worker: Worker = undefined;
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });
    defer worker.stop(io);

    for (0..queue_depth + 1) |index| {
        const frame = try std.testing.allocator.create(Frame);
        frame.* = .{
            .gpa = std.testing.allocator,
            .event_id = index,
            .pane = @enumFromInt(1),
            .pane_generation = 1,
            .storage = try std.testing.allocator.alloc(u8, 1),
            .len = 1,
        };
        worker.submit(io, frame);
    }

    try std.testing.expectEqual(@as(u64, 1), worker.dropped.load(.monotonic));
}

test "five restarts in one window disable a worker" {
    var worker: Worker = undefined;
    var result_storage: [1]*effects.Result = undefined;
    var results: Io.Queue(*effects.Result) = .init(&result_storage);
    worker.init(.{ .gpa = std.testing.allocator, .spec = undefined, .results = &results });

    for (0..restart_limit) |_| worker.recordRestart(std.testing.io);

    try std.testing.expect(worker.disabled);
}

test "submit hands exchanges to the encoder actor and frees them off the loop" {
    const io = std.testing.io;
    const capture = @import("../proxy/capture/root.zig");
    var quota = capture.Quota.init(64);
    const credential: @import("../proxy/identity.zig").Credential = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 1,
        .token = .{0x5a} ** @import("../proxy/identity.zig").token_bytes,
    };
    var spec: Spec = undefined;
    spec.generation = 3;
    var service: Service = undefined;
    service = .{ .gpa = std.testing.allocator, .io = io };
    service.results = .init(&service.result_storage);
    service.exchanges = .init(&service.exchange_storage);
    service.workers[0].init(.{ .gpa = std.testing.allocator, .spec = spec, .results = &service.results });
    service.workers[0].disabled = true;
    service.worker_count = 1;
    service.encoder = try io.concurrent(Service.encodeExchanges, .{ &service, io });
    defer service.deinit();

    const half = capture.Half.create(.{
        .gpa = std.testing.allocator,
        .quota = &quota,
        .config = .{ .enabled = true, .max_part_bytes = 8, .max_exchange_bytes = 16, .max_total_bytes = 64 },
        .credential = credential,
        .dialect = .unknown,
        .protocol = .h2,
        .key = .{ .connection_id = 3, .stream_id = 5 },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
    var exchange: proxy.CaptureExchange = .{ .request = half };

    service.submit(&exchange);

    // Ownership moved: the caller's exchange is empty and the encoder, not
    // the loop, assigns the event id while producing the worker frame.
    try std.testing.expect(exchange.request == null);
    var waited: usize = 0;
    while (service.next_event_id.load(.monotonic) == 1 and waited < 2000) : (waited += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 2), service.next_event_id.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), service.droppedExchanges());
}
