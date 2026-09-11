const std = @import("std");
const ServiceSpec = @import("ServiceSpec.zig");
const ResultType = @import("Result.zig");
const Frame = @import("Frame.zig");
const service_support = @import("service_support.zig");
const SessionType = @import("Session.zig");
const WorkerInitOptions = @import("WorkerInitOptions.zig");
const Worker = @This();

gpa: std.mem.Allocator,
spec: ServiceSpec,
results: *std.Io.Queue(*ResultType),
requests: std.Io.Queue(*Frame) = undefined,
request_storage: [service_support.queue_depth]*Frame = undefined,
session: ?*SessionType = null,
future: ?std.Io.Future(anyerror!void) = null,
restarts: [service_support.restart_limit]i64 = .{0} ** service_support.restart_limit,
restart_count: u8 = 0,
disabled: bool = false,
dropped: std.atomic.Value(u64) = .init(0),

pub fn init(worker: *Worker, options: WorkerInitOptions) void {
    worker.* = .{ .gpa = options.gpa, .spec = options.spec, .results = options.results };
    worker.requests = .init(&worker.request_storage);
}

pub fn start(worker: *Worker, io: std.Io) !void {
    worker.future = try io.concurrent(run, .{ worker, io });
}

pub fn stop(worker: *Worker, io: std.Io) void {
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

pub fn submit(worker: *Worker, io: std.Io, frame: *Frame) void {
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

fn run(worker: *Worker, io: std.Io) anyerror!void {
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

fn ensureSession(worker: *Worker, io: std.Io) !*SessionType {
    if (worker.session) |session| {
        return session;
    }
    worker.session = try SessionType.open(io, worker.gpa, .{ .entry = worker.spec.entry(), .timeout_ms = 200 });
    return worker.session.?;
}

fn closeSession(worker: *Worker) void {
    const session = worker.session orelse return;
    worker.session = null;
    session.close();
}

pub fn recordRestart(worker: *Worker, io: std.Io) void {
    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    if (worker.restart_count < service_support.restart_limit) {
        worker.restarts[worker.restart_count] = now_ms;
        worker.restart_count += 1;
        if (worker.restart_count == service_support.restart_limit and now_ms - worker.restarts[0] <= service_support.restart_window_ms) {
            worker.disabled = true;
        }
        return;
    }
    if (now_ms - worker.restarts[0] <= service_support.restart_window_ms) {
        worker.disabled = true;
        return;
    }
    std.mem.copyForwards(i64, worker.restarts[0 .. service_support.restart_limit - 1], worker.restarts[1..]);
    worker.restarts[service_support.restart_limit - 1] = now_ms;
}
