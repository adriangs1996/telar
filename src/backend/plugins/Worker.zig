const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const Result = @import("Result.zig");
const Frame = @import("Frame.zig");
const service_support = @import("service_support.zig");
const Session = @import("Session.zig");
const Worker = @This();

gpa: std.mem.Allocator,
spec: ServiceSpec,
results: *std.Io.Queue(*Result),
requests: std.Io.Queue(*Frame) = undefined,
request_storage: [service_support.queue_depth]*Frame = undefined,
session: ?*Session = null,
future: ?std.Io.Future(anyerror!void) = null,
restarts: [service_support.restart_limit]i64 = .{0} ** service_support.restart_limit,
restart_count: u8 = 0,
/// Set by the worker thread after `restart_limit` restarts in the window;
/// the runtime reads it to report the plugin.
disabled: std.atomic.Value(bool) = .init(false),
/// Frames dropped because the queue held `queue_depth`.
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
        var pending: [1]*Frame = undefined;
        const count = self.requests.getUncancelable(io, &pending, 0) catch break;
        if (count == 0) {
            break;
        }
        pending[0].deinit();
    }
}

pub fn submit(self: *Worker, io: std.Io, frame: *Frame) void {
    if (self.disabled.load(.monotonic)) {
        frame.deinit();
        return;
    }

    if ((self.requests.put(io, &.{frame}, 0) catch 0) == 1) {
        return;
    }
    var oldest: [1]*Frame = undefined;
    if ((self.requests.getUncancelable(io, &oldest, 0) catch 0) == 1) {
        oldest[0].deinit();
        _ = self.dropped.fetchAdd(1, .monotonic);
    }
    if ((self.requests.put(io, &.{frame}, 0) catch 0) != 1) {
        frame.deinit();
        _ = self.dropped.fetchAdd(1, .monotonic);
    }
}

fn run(self: *Worker, io: std.Io) anyerror!void {
    while (true) {
        const frame = self.requests.getOne(io) catch return;
        defer frame.deinit();
        if (self.disabled.load(.monotonic)) {
            continue;
        }
        const session = self.ensureSession(io) catch {
            self.recordRestart(io);
            continue;
        };
        const result = session.exchange(.{
            .package_index = self.spec.package_index,
            .plugin_id = self.spec.plugin_id,
            .digest = self.spec.digest,
            .generation = self.spec.generation,
        }, .{
            .event_id = frame.event_id,
            .bytes = frame.bytes(),
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
