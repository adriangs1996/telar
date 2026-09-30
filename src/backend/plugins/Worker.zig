const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const Result = @import("Result.zig");
const SharedExchange = @import("SharedExchange.zig");
const ExchangeIdentity = @import("ExchangeIdentity.zig");
const protocol = @import("protocol.zig");
const service_support = @import("service_support.zig");
const Session = @import("Session.zig");
const Worker = @This();

gpa: std.mem.Allocator,
spec: ServiceSpec,
results: *std.Io.Queue(*Result),
requests: std.Io.Queue(*SharedExchange) = undefined,
request_storage: [service_support.queue_depth]*SharedExchange = undefined,
session: ?*Session = null,
future: ?std.Io.Future(anyerror!void) = null,
restarts: [service_support.restart_limit]i64 = .{0} ** service_support.restart_limit,
restart_count: u8 = 0,
/// Set by the worker thread after `restart_limit` restarts in the window;
/// the runtime reads it to report the plugin.
disabled: std.atomic.Value(bool) = .init(false),
/// Exchanges dropped because the queue held `queue_depth`.
dropped: std.atomic.Value(u64) = .init(0),
/// Replies that did not arrive within `reply_timeout_ms`.
timeouts: std.atomic.Value(u64) = .init(0),

pub fn init(self: *Worker, options: WorkerInitOptions) void {
    self.* = .{ .gpa = options.gpa, .spec = options.spec, .results = options.results };
    self.requests = .init(&self.request_storage);
}

pub fn start(self: *Worker, io: std.Io) !void {
    self.future = try io.concurrent(run, .{ self, io });
}

pub fn stop(self: *Worker, io: std.Io) void {
    self.requests.close(io);
    if (self.future) |*future| {
        _ = future.await(io) catch {};
        self.future = null;
    }
    self.closeSession();
    while (true) {
        var pending: [1]*SharedExchange = undefined;
        const count = self.requests.getUncancelable(io, &pending, 0) catch break;
        if (count == 0) {
            break;
        }
        pending[0].release();
    }
}

/// Queues one shared exchange, dropping the oldest when the queue is full;
/// every exchange the worker does not keep is released.
///
/// ```zig
/// worker.submit(io, shared);
/// ```
pub fn submit(self: *Worker, io: std.Io, shared: *SharedExchange) void {
    if (self.disabled.load(.monotonic)) {
        shared.release();
        return;
    }

    if ((self.requests.put(io, &.{shared}, 0) catch 0) == 1) {
        return;
    }

    var oldest: [1]*SharedExchange = undefined;
    if ((self.requests.getUncancelable(io, &oldest, 0) catch 0) == 1) {
        oldest[0].release();
        _ = self.dropped.fetchAdd(1, .monotonic);
    }

    if ((self.requests.put(io, &.{shared}, 0) catch 0) != 1) {
        shared.release();
        _ = self.dropped.fetchAdd(1, .monotonic);
    }
}

fn run(self: *Worker, io: std.Io) anyerror!void {
    while (true) {
        const shared = self.requests.getOne(io) catch return;
        defer shared.release();
        if (self.disabled.load(.monotonic)) {
            continue;
        }

        const session = self.ensureSession(io) catch {
            self.recordRestart(io);
            continue;
        };

        const frame = self.encode(shared) orelse continue;
        defer {
            std.crypto.secureZero(u8, frame.storage);
            self.gpa.free(frame.storage);
            shared.budget.release(frame.storage.len);
        }

        const result = session.exchange(.{
            .package_index = self.spec.package_index,
            .plugin_id = self.spec.plugin_id,
            .digest = self.spec.digest,
            .generation = self.spec.generation,
        }, .{
            .event_id = shared.event_id,
            .bytes = frame.bytes,
        }) catch |err| {
            if (err == error.WorkerTimeout) {
                _ = self.timeouts.fetchAdd(1, .monotonic);
            }

            if (err != error.WorkerEventFailed) {
                self.closeSession();
                self.recordRestart(io);
            }
            continue;
        };

        if ((self.results.put(io, &.{result}, 0) catch 0) != 1) {
            result.deinit();
        }
    }
}

/// Encodes this worker's frame of a shared exchange on the worker's thread,
/// charged to the tap's budget; null when the frame does not fit, which the
/// budget counts, or cannot be encoded.
fn encode(self: *Worker, shared: *SharedExchange) ?EncodedFrame {
    const identity: ExchangeIdentity = .{
        .id = shared.event_id,
        .generation = self.spec.generation,
    };
    const size = service_support.capturedBytes(&shared.exchange) + protocol.overhead_bytes;
    if (!shared.budget.charge(size)) {
        return null;
    }

    const storage = self.gpa.alloc(u8, size) catch {
        shared.budget.release(size);
        return null;
    };

    const payload = protocol.encodeExchange(storage, identity, &shared.exchange) catch {
        self.gpa.free(storage);
        shared.budget.release(size);
        return null;
    };

    return .{
        .storage = storage,
        .bytes = payload,
    };
}

/// One encoded frame: the storage to free and the bytes to send.
const EncodedFrame = struct {
    storage: []u8,
    bytes: []const u8,
};

fn ensureSession(self: *Worker, io: std.Io) !*Session {
    if (self.session) |session| {
        return session;
    }
    self.session = try Session.open(io, self.gpa, .{
        .entry = self.spec.entry(),
        .timeout_ms = service_support.reply_timeout_ms,
    });
    return self.session.?;
}

fn closeSession(self: *Worker) void {
    const session = self.session orelse return;
    self.session = null;
    session.close();
}

pub fn recordRestart(self: *Worker, io: std.Io) void {
    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    if (self.restart_count < service_support.restart_limit) {
        self.restarts[self.restart_count] = now_ms;
        self.restart_count += 1;
        if (self.restart_count == service_support.restart_limit and now_ms - self.restarts[0] <= service_support.restart_window_ms) {
            self.disabled.store(true, .monotonic);
        }
        return;
    }
    if (now_ms - self.restarts[0] <= service_support.restart_window_ms) {
        self.disabled.store(true, .monotonic);
        return;
    }
    std.mem.copyForwards(i64, self.restarts[0 .. service_support.restart_limit - 1], self.restarts[1..]);
    self.restarts[service_support.restart_limit - 1] = now_ms;
}

const WorkerInitOptions = struct {
    gpa: std.mem.Allocator,
    spec: ServiceSpec,
    results: *std.Io.Queue(*Result),
};
