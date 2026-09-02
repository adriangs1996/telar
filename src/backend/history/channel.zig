//! Bounded ownership transfer between history producers and the worker.

const std = @import("std");
const metrics_mod = @import("metrics.zig");
const model = @import("model.zig");

const request_capacity = 64;
const response_capacity = 4;

pub const Submission = struct {
    io: std.Io,
    request: model.Request,
    metrics: *metrics_mod.Counters,
};

pub const Channel = struct {
    gpa: std.mem.Allocator,
    requests: std.Io.Queue(model.Request),
    responses: std.Io.Queue(model.Response),
    request_storage: []model.Request,
    response_storage: []model.Response,

    /// Allocates the fixed-capacity request and response rings. No worker is
    /// started and ownership of no message changes during initialization.
    ///
    /// ```zig
    /// var channel = try Channel.init(gpa);
    /// defer channel.deinit(io);
    /// ```
    pub fn init(gpa: std.mem.Allocator) !Channel {
        const request_storage = try gpa.alloc(model.Request, request_capacity);
        errdefer gpa.free(request_storage);

        const response_storage = try gpa.alloc(model.Response, response_capacity);
        errdefer gpa.free(response_storage);

        return .{
            .gpa = gpa,
            .requests = .init(request_storage),
            .responses = .init(response_storage),
            .request_storage = request_storage,
            .response_storage = response_storage,
        };
    }

    /// Closes both directions so blocked producers and the worker can stop.
    /// Queued values remain owned by the channel until `deinit` drains them.
    ///
    /// ```zig
    /// channel.close(io);
    /// ```
    pub fn close(channel: *Channel, io: std.Io) void {
        channel.requests.close(io);
        channel.responses.close(io);
    }

    /// Releases every request and response still owned by the channel, then
    /// frees both queue rings. The worker must already have stopped.
    ///
    /// ```zig
    /// channel.deinit(io);
    /// ```
    pub fn deinit(channel: *Channel, io: std.Io) void {
        channel.responses.close(io);

        var request_buffer: [8]model.Request = undefined;
        while (true) {
            const count = channel.requests.get(io, &request_buffer, 0) catch break;
            if (count == 0) {
                break;
            }

            for (request_buffer[0..count]) |request| {
                model.deinitRequest(request, channel.gpa);
            }
        }

        var response_buffer: [response_capacity]model.Response = undefined;
        while (true) {
            const count = channel.responses.get(io, &response_buffer, 0) catch break;
            if (count == 0) {
                break;
            }

            for (response_buffer[0..count]) |response| {
                model.deinitResponse(response, channel.gpa);
            }
        }

        channel.gpa.free(channel.response_storage);
        channel.gpa.free(channel.request_storage);
    }

    /// Offers one owned request without blocking. Success transfers ownership
    /// to the worker. Refusal destroys the request and records one drop.
    ///
    /// ```zig
    /// if (!channel.submit(.{ .io = io, .request = request, .metrics = metrics })) return error.HistoryQueueFull;
    /// ```
    pub fn submit(channel: *Channel, submission: Submission) bool {
        const depth = submission.metrics.beginSubmission();
        const count = channel.requests.put(submission.io, &.{submission.request}, 0) catch 0;
        if (count == 1) {
            submission.metrics.acceptSubmission(depth);
            return true;
        }

        submission.metrics.dropSubmission();
        model.deinitRequest(submission.request, channel.gpa);
        return false;
    }

    /// Waits for one request and transfers its ownership from the channel to
    /// the worker while releasing its observable queue position.
    ///
    /// ```zig
    /// const request = try channel.receiveRequest(io, metrics);
    /// ```
    pub fn receiveRequest(channel: *Channel, io: std.Io, metrics: *metrics_mod.Counters) !model.Request {
        const request = try channel.requests.getOne(io);
        metrics.completeDequeue();
        return request;
    }

    /// Transfers one owned response to the bounded consumer queue.
    ///
    /// ```zig
    /// try channel.sendResponse(io, response);
    /// ```
    pub fn sendResponse(channel: *Channel, io: std.Io, response: model.Response) !void {
        try channel.responses.putOne(io, response);
    }

    /// Waits for the next response and transfers its ownership to the caller.
    ///
    /// ```zig
    /// const response = try channel.receiveResponse(io);
    /// ```
    pub fn receiveResponse(channel: *Channel, io: std.Io) !model.Response {
        return channel.responses.getOne(io);
    }
};

test "accepted requests transfer to the worker and release their queue depth" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    var metrics: metrics_mod.Counters = .{};
    const finished: model.SessionFinished = .{ .id = @splat(1), .finished_at_ms = 42 };

    try std.testing.expect(channel.submit(.{
        .io = io,
        .request = .{ .session_finished = finished },
        .metrics = &metrics,
    }));
    const request = try channel.receiveRequest(io, &metrics);

    try std.testing.expectEqual(finished, request.session_finished);
    try std.testing.expectEqual(@as(u64, 0), metrics.snapshot(true).queued);
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot(true).queue_high_water);
}

test "a full request queue refuses work without exceeding its bound" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    var metrics: metrics_mod.Counters = .{};

    for (0..request_capacity) |index| {
        try std.testing.expect(channel.submit(.{
            .io = io,
            .request = .{ .session_finished = .{ .id = @splat(@intCast(index)), .finished_at_ms = @intCast(index) } },
            .metrics = &metrics,
        }));
    }

    try std.testing.expect(!channel.submit(.{
        .io = io,
        .request = .{ .session_finished = .{ .id = @splat(0xff), .finished_at_ms = 65 } },
        .metrics = &metrics,
    }));

    const current = metrics.snapshot(true);

    try std.testing.expectEqual(@as(u64, request_capacity), current.queued);
    try std.testing.expectEqual(@as(u64, request_capacity), current.queue_high_water);
    try std.testing.expectEqual(@as(u64, 1), current.dropped);
}

test "responses cross the channel without changing their correlation" {
    const io = std.testing.io;
    var channel = try Channel.init(std.testing.allocator);
    defer channel.deinit(io);
    const expected: model.Pruned = .{
        .request_id = @enumFromInt(7),
        .origin = .{ .client = .{ .id = 3, .generation = 4 }, .close_after_reply = false },
        .removed = 9,
    };

    try channel.sendResponse(io, .{ .pruned = expected });
    const response = try channel.receiveResponse(io);

    try std.testing.expectEqual(expected, response.pruned);
}
