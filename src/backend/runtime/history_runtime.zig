//! Runtime ownership for the asynchronous history service.

const std = @import("std");
const history = @import("../history/root.zig");

const Io = std.Io;
const Worker = Io.Future(anyerror!void);

fn Port(comptime StateType: type, comptime WorkerType: type) type {
    return struct {
        start: *const fn (*StateType) anyerror!WorkerType,
        close: *const fn (*StateType) void,
        join: *const fn (*StateType, *WorkerType) void,
        destroy: *const fn (*StateType) void,
    };
}

fn Lifecycle(comptime StateType: type, comptime WorkerType: type, comptime port: Port(StateType, WorkerType)) type {
    return struct {
        const Self = @This();

        state: *StateType,
        worker: WorkerType,

        fn start(state: *StateType) !Self {
            errdefer port.destroy(state);

            return .{
                .state = state,
                .worker = try port.start(state),
            };
        }

        fn deinit(lifecycle: *Self) void {
            port.close(lifecycle.state);
            port.join(lifecycle.state, &lifecycle.worker);
            port.destroy(lifecycle.state);
        }
    };
}

const RuntimeState = struct {
    io: Io,
    gpa: std.mem.Allocator,
    service: history.Service,
};

fn startWorker(state: *RuntimeState) !Worker {
    return state.io.concurrent(history.runWorker, .{ state.io, &state.service });
}

fn closeQueues(state: *RuntimeState) void {
    state.service.closeQueues(state.io);
}

fn joinWorker(state: *RuntimeState, worker: *Worker) void {
    _ = worker.await(state.io) catch {};
}

fn destroyState(state: *RuntimeState) void {
    const gpa = state.gpa;
    state.service.deinit(state.io);
    gpa.destroy(state);
}

const lifecycle_port: Port(RuntimeState, Worker) = .{
    .start = startWorker,
    .close = closeQueues,
    .join = joinWorker,
    .destroy = destroyState,
};

const HistoryLifecycle = Lifecycle(RuntimeState, Worker, lifecycle_port);

pub const Runtime = struct {
    lifecycle: HistoryLifecycle,

    /// Creates the history service at a stable address and starts its worker.
    /// A database-open failure keeps the service alive in degraded mode.
    ///
    /// ```zig
    /// var history_runtime = try Runtime.init(io, gpa, ":memory:");
    /// defer history_runtime.deinit();
    /// ```
    pub fn init(io: Io, gpa: std.mem.Allocator, database_path: [:0]const u8) !Runtime {
        const state = try gpa.create(RuntimeState);
        const history_service = history.Service.init(gpa, database_path) catch |err| {
            gpa.destroy(state);
            return err;
        };
        state.* = .{
            .io = io,
            .gpa = gpa,
            .service = history_service,
        };

        return .{ .lifecycle = try HistoryLifecycle.start(state) };
    }

    /// Borrows the history service for as long as this runtime remains alive.
    ///
    /// ```zig
    /// const service = history_runtime.service();
    /// ```
    pub fn service(runtime: *Runtime) *history.Service {
        return &runtime.lifecycle.state.service;
    }

    /// Closes both queues, joins the worker, and releases every queued value
    /// still owned by the service.
    ///
    /// ```zig
    /// history_runtime.deinit();
    /// ```
    pub fn deinit(runtime: *Runtime) void {
        runtime.lifecycle.deinit();
    }
};

const Step = enum {
    start,
    close,
    join,
    destroy,
};

const Capture = struct {
    steps: [4]Step = undefined,
    len: usize = 0,
    start_fails: bool = false,
    closed: bool = false,
    joined: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }
};

const FakeState = struct {
    capture: *Capture,
};

const FakeWorker = struct {};

fn startFakeWorker(state: *FakeState) !FakeWorker {
    state.capture.record(.start);

    if (state.capture.start_fails) {
        return error.WorkerUnavailable;
    }

    return .{};
}

fn closeFakeQueues(state: *FakeState) void {
    std.debug.assert(!state.capture.joined);
    state.capture.record(.close);
    state.capture.closed = true;
}

fn joinFakeWorker(state: *FakeState, _: *FakeWorker) void {
    std.debug.assert(state.capture.closed);
    state.capture.record(.join);
    state.capture.joined = true;
}

fn destroyFakeState(state: *FakeState) void {
    if (!state.capture.start_fails) {
        std.debug.assert(state.capture.joined);
    }

    state.capture.record(.destroy);
}

const test_port: Port(FakeState, FakeWorker) = .{
    .start = startFakeWorker,
    .close = closeFakeQueues,
    .join = joinFakeWorker,
    .destroy = destroyFakeState,
};

const TestLifecycle = Lifecycle(FakeState, FakeWorker, test_port);

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn createAndDestroy(gpa: std.mem.Allocator) !void {
    var runtime = try Runtime.init(std.testing.io, gpa, ":memory:");
    runtime.deinit();
}

test "worker startup failure releases transferred service ownership" {
    var capture: Capture = .{ .start_fails = true };
    var state: FakeState = .{ .capture = &capture };

    try std.testing.expectError(error.WorkerUnavailable, TestLifecycle.start(&state));
    try expectSteps(&capture, &.{ .start, .destroy });
}

test "shutdown closes queues before joining and destroying history" {
    var capture: Capture = .{};
    var state: FakeState = .{ .capture = &capture };
    var lifecycle = try TestLifecycle.start(&state);

    lifecycle.deinit();

    try expectSteps(&capture, &.{ .start, .close, .join, .destroy });
}

test "every allocation failure rolls back history runtime ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDestroy, .{});
}

test "database open failure starts a queryable degraded worker" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/history.db", .{directory_buffer[0..directory_len]});
    var runtime = try Runtime.init(io, std.testing.allocator, path);
    defer runtime.deinit();
    const service_value = runtime.service();

    try std.testing.expect(!service_value.statsSnapshot().available);
    try std.testing.expect(service_value.openError() != null);
    const query = try history.Query.init(.{
        .request_id = @enumFromInt(7),
        .origin = .{
            .client = .{ .id = 3, .generation = 5 },
            .close_after_reply = false,
        },
    });
    try std.testing.expect(service_value.query(io, query));
    const response = try history.receiveResponse(io, service_value);
    defer history.model.deinitResponse(response, std.testing.allocator);

    try std.testing.expect(response == .failed);
    try std.testing.expectEqualStrings("history database is unavailable", response.failed.message);
}
