//! Experimental coordinator transport. No sockets, JSON or parsing on UI input.
const client = @import("telar-client");
const std = @import("std");
const native = @import("../../native/native.zig");
const LiveSnapshot = @import("LiveSnapshot.zig");
const ReviewSubmission = @import("ReviewSubmission.zig");
const Self = @This();
const Operation = enum { load, submit, wait };

allocator: std.mem.Allocator,
io: std.Io,
address: std.Io.net.UnixAddress,
wake_fd: c_int,
initial: ?*LiveSnapshot = null,
result: ?*LiveSnapshot = null,
failure: ?anyerror = null,
submission: ReviewSubmission = .{},
queue: std.Io.Queue(Operation) = undefined,
queue_storage: [1]Operation = undefined,
worker: ?std.Io.Future(void) = null,
ready: std.atomic.Value(bool) = .init(false),
attempted: bool = false,
exchange_result: anyerror!*LiveSnapshot = error.NoReviewResponse,

/// Starts one waiting worker after loading an initial immutable snapshot.
/// Example: `const bridge = try LiveBridge.open(init, .{ .path = path, .wake_fd = fd });`
pub fn open(init: std.process.Init, options: struct { path: []const u8, wake_fd: c_int }) !*Self {
    if (!std.fs.path.isAbsolute(options.path)) {
        return error.InvalidReviewEndpoint;
    }

    const address = try std.Io.net.UnixAddress.init(options.path);
    const self = try init.gpa.create(Self);
    self.* = .{ .allocator = init.gpa, .io = init.io, .address = address, .wake_fd = options.wake_fd };
    errdefer self.deinit();
    self.initial = try self.exchangeBounded(.load);
    self.queue = .init(&self.queue_storage);
    self.worker = try init.io.concurrent(run, .{self});
    if (self.initial.?.parsed.value.status == .working) {
        _ = try self.queue.put(self.io, &.{.wait}, 0);
        self.attempted = true;
    }
    return self;
}

/// Cancels only this client's socket wait; the coordinator owns the agent turn.
/// Example: `defer bridge.deinit();`
pub fn deinit(self: *Self) void {
    if (self.worker) |*worker| {
        self.queue.close(self.io);
        worker.cancel(self.io);
    }

    if (self.initial) |snapshot| {
        snapshot.deinit();
    }
    if (self.result) |snapshot| {
        snapshot.deinit();
    }
    self.allocator.destroy(self);
}

/// Bounded copy and nonblocking enqueue; the worker serializes and sends it.
/// Example: `try bridge.submit(&widget.model);`
pub fn submit(self: *Self, model: *const client.ChangeReviewModel) !void {
    if (self.attempted) {
        return error.ReviewAlreadySubmitted;
    }

    try self.submission.capture(model, self.initial.?.parsed.value.revisions[0].id);
    if ((try self.queue.put(self.io, &.{.submit}, 0)) != 1) {
        return error.ReviewDeliveryBusy;
    }
    self.attempted = true;
}

fn run(self: *Self) void {
    const operation = self.queue.getOne(self.io) catch return;
    self.result = self.exchangeBounded(operation) catch |err| blk: {
        self.failure = err;
        break :blk null;
    };
    self.ready.store(true, .release);
    native.telar_gui_wake(self.wake_fd);
}

fn exchangeBounded(self: *Self, operation: Operation) !*LiveSnapshot {
    const Result = union(enum) { finished: void, timeout: anyerror!void };
    var storage: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(self.io, &storage);
    var adopted = false;
    defer {
        select.cancelDiscard();
        if (!adopted) {
            if (self.exchange_result) |snapshot| {
                snapshot.deinit();
            } else |_| {}
        }
        self.exchange_result = error.NoReviewResponse;
    }
    try select.concurrent(.finished, execute, .{ self, operation });
    try select.concurrent(.timeout, deadline, .{self});
    switch (try select.await()) {
        .finished => {
            const result = try self.exchange_result;
            adopted = true;
            return result;
        },
        .timeout => |result| {
            try result;
            return error.ReviewTimeout;
        },
    }
}

fn deadline(self: *Self) !void {
    try self.io.sleep(.fromSeconds(180), .awake);
}

fn execute(self: *Self, operation: Operation) void {
    self.exchange_result = self.exchange(operation);
}

fn exchange(self: *Self, operation: Operation) !*LiveSnapshot {
    const stream = try self.address.connect(self.io);
    defer stream.close(self.io);
    var request: std.Io.Writer.Allocating = .init(self.allocator);
    defer request.deinit();
    if (operation == .submit) {
        try self.submission.write(&request.writer);
    } else {
        try std.json.Stringify.value(.{ .schema = 1, .action = @tagName(operation) }, .{}, &request.writer);
    }

    if (request.written().len > LiveSnapshot.max_bytes) {
        return error.ReviewRequestTooLarge;
    }
    var output_buffer: [4096]u8 = undefined;
    var output = stream.writer(self.io, &output_buffer);
    try output.interface.writeInt(u32, @intCast(request.written().len), .little);
    try output.interface.writeAll(request.written());
    try output.interface.flush();
    var input_buffer: [4096]u8 = undefined;
    var input = stream.reader(self.io, &input_buffer);
    const length = try input.interface.takeInt(u32, .little);
    if (length == 0 or length > LiveSnapshot.max_bytes) {
        return error.ReviewResponseTooLarge;
    }
    const bytes = try self.allocator.alloc(u8, length);
    defer self.allocator.free(bytes);
    try input.interface.readSliceAll(bytes);
    return LiveSnapshot.parse(self.io, self.allocator, bytes);
}
