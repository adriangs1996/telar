//! The engine actor: bounded request and response rings around one
//! sequential worker that owns at most one child session.
//!
//! Requests queue behind the actor, the child starts on the first prompt,
//! and it is killed after an idle interval or on any protocol failure so
//! the next prompt starts a fresh process.

const std = @import("std");
const session_mod = @import("session.zig");
const types = @import("types.zig");

const Io = std.Io;
const Options = types.Options;
const Prompt = types.Prompt;
const Request = types.Request;
const Response = types.Response;
const Session = session_mod.Session;

/// The service must live at a stable address for as long as `run` executes.
pub const Service = struct {
    gpa: std.mem.Allocator,
    options: Options,
    requests: Io.Queue(Request),
    responses: Io.Queue(Response),
    request_storage: []Request,
    response_storage: []Response,
    session: ?*Session = null,
    child_alive: std.atomic.Value(bool) = .init(false),
    idle_check_pending: std.atomic.Value(bool) = .init(false),

    /// Allocates the rings. No child is started.
    ///
    /// ```zig
    /// var service = try Service.init(gpa, options);
    /// defer service.deinit(io);
    /// ```
    pub fn init(gpa: std.mem.Allocator, options: Options) !Service {
        const request_storage = try gpa.alloc(Request, types.max_pending_requests);
        errdefer gpa.free(request_storage);
        const response_storage = try gpa.alloc(Response, types.max_pending_requests);
        errdefer gpa.free(response_storage);

        return .{
            .gpa = gpa,
            .options = options,
            .requests = .init(request_storage),
            .responses = .init(response_storage),
            .request_storage = request_storage,
            .response_storage = response_storage,
        };
    }

    /// Closes both rings so `run` returns and blocked receivers fail.
    ///
    /// ```zig
    /// service.stop(io);
    /// ```
    pub fn stop(service: *Service, io: Io) void {
        service.requests.close(io);
        service.responses.close(io);
    }

    /// Kills a live child and frees the rings. `run` must have returned.
    ///
    /// ```zig
    /// service.deinit(io);
    /// ```
    pub fn deinit(service: *Service, io: Io) void {
        service.responses.close(io);
        service.closeSession(io);
        service.gpa.free(service.request_storage);
        service.gpa.free(service.response_storage);
    }

    /// Queues one request without blocking. Returns false when the ring is
    /// full or closed; the caller decides whether that is a failure.
    ///
    /// ```zig
    /// if (!service.submit(io, .{ .prompt = prompt })) return error.EngineBusy;
    /// ```
    pub fn submit(service: *Service, io: Io, request: Request) bool {
        const queued = service.requests.put(io, &.{request}, 0) catch return false;
        return queued == 1;
    }

    /// Asks the actor to kill an idle child. Cheap to call on every
    /// maintenance tick: it queues nothing while no child is alive or while
    /// a check is already pending.
    ///
    /// ```zig
    /// service.requestIdleCheck(io);
    /// ```
    pub fn requestIdleCheck(service: *Service, io: Io) void {
        if (!service.child_alive.load(.acquire)) {
            return;
        }

        if (service.idle_check_pending.swap(true, .acq_rel)) {
            return;
        }

        if (!service.submit(io, .idle_check)) {
            service.idle_check_pending.store(false, .release);
        }
    }

    /// Waits for the next reply. Fails once the service is stopped.
    ///
    /// ```zig
    /// const response = try service.receiveResponse(io);
    /// ```
    pub fn receiveResponse(service: *Service, io: Io) anyerror!Response {
        return service.responses.getOne(io);
    }

    /// Serves requests in order until `stop` closes the ring.
    ///
    /// ```zig
    /// var worker = try io.concurrent(Service.run, .{ &service, io });
    /// ```
    pub fn run(service: *Service, io: Io) anyerror!void {
        while (true) {
            const request = service.requests.getOne(io) catch return;
            service.handle(io, request);
        }
    }

    /// Applies one request on the actor. Public so tests drive the actor
    /// synchronously; `run` is this in a loop.
    ///
    /// ```zig
    /// service.handle(io, .idle_check);
    /// ```
    pub fn handle(service: *Service, io: Io, request: Request) void {
        switch (request) {
            .idle_check => {
                service.idle_check_pending.store(false, .release);
                const session = service.session orelse return;
                if (session.idleMs(io) >= service.options.idle_timeout_ms) {
                    service.closeSession(io);
                }
            },
            .prompt => |*prompt| {
                const response = service.answer(io, prompt);
                service.responses.putOne(io, response) catch {};
            },
        }
    }

    /// Answers on the live child, or a fresh one. A child that timed out or
    /// broke the protocol is discarded; one that merely answered badly is
    /// kept, because its next reply may be fine.
    fn answer(service: *Service, io: Io, prompt: *const Prompt) Response {
        var response: Response = .{ .purpose = prompt.purpose, .status = .failed };
        const session = service.ensureSession(io) catch |err| {
            response.status = if (err == error.FileNotFound) .unavailable else .failed;
            return response;
        };

        response.status = session.ask(io, prompt.slice(), &response);
        session.touch(io);

        switch (response.status) {
            .success, .invalid_output => {},
            .unavailable, .timeout, .failed => service.closeSession(io),
        }

        return response;
    }

    fn ensureSession(service: *Service, io: Io) !*Session {
        if (service.session) |session| {
            return session;
        }

        const session = try Session.open(io, service.gpa, service.options);
        service.session = session;
        service.child_alive.store(true, .release);
        return session;
    }

    fn closeSession(service: *Service, io: Io) void {
        const session = service.session orelse return;
        service.session = null;
        service.child_alive.store(false, .release);
        session.close(io);
    }
};

const fakes = @import("testing.zig");

fn testService(arguments: []const []const u8, timeout_ms: u32, idle_timeout_ms: u32) !Service {
    return Service.init(std.testing.allocator, fakes.options(arguments, timeout_ms, idle_timeout_ms));
}

test "the actor answers prompts over one child and reuses it" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fakes.fake_engine }, 5000, 60_000);
    defer service.deinit(io);

    const prompt = try Prompt.init(fakes.purpose, "Create a title");
    service.handle(io, .{ .prompt = prompt });
    var response = try service.receiveResponse(io);
    try std.testing.expectEqual(types.Status.success, response.status);
    try std.testing.expectEqualStrings("Improve agent sidebar", response.textSlice());
    try std.testing.expectEqual(@as(u64, 7), response.purpose.suggestion.client_id);
    try std.testing.expect(service.child_alive.load(.acquire));
    const first = service.session.?;

    service.handle(io, .{ .prompt = prompt });
    response = try service.receiveResponse(io);
    try std.testing.expectEqual(types.Status.success, response.status);
    try std.testing.expect(service.session.? == first);

    // Still fresh: the idle check keeps the child.
    service.handle(io, .idle_check);
    try std.testing.expect(service.session != null);
}

test "an idle check kills a child past the idle interval" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fakes.fake_engine }, 5000, 0);
    defer service.deinit(io);

    service.handle(io, .{ .prompt = try Prompt.init(fakes.purpose, "Create a title") });
    _ = try service.receiveResponse(io);
    try std.testing.expect(service.child_alive.load(.acquire));

    service.requestIdleCheck(io);
    try std.testing.expect(service.idle_check_pending.load(.acquire));
    service.handle(io, try service.requests.getOne(io));
    try std.testing.expect(service.session == null);
    try std.testing.expect(!service.child_alive.load(.acquire));
    try std.testing.expect(!service.idle_check_pending.load(.acquire));

    // Nothing alive: the check queues nothing.
    service.requestIdleCheck(io);
    try std.testing.expect(!service.idle_check_pending.load(.acquire));
}

test "a broken child is discarded and a bad reply keeps it" {
    const io = std.testing.io;
    const prompt = try Prompt.init(fakes.purpose, "Create a title");

    var silent = try testService(&.{ "/bin/sh", "-c", fakes.silent_engine }, 100, 60_000);
    defer silent.deinit(io);
    silent.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(types.Status.timeout, (try silent.receiveResponse(io)).status);
    try std.testing.expect(silent.session == null);
    try std.testing.expect(!silent.child_alive.load(.acquire));

    var empty = try testService(&.{ "/bin/sh", "-c", fakes.empty_reply_engine }, 1000, 60_000);
    defer empty.deinit(io);
    empty.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(types.Status.invalid_output, (try empty.receiveResponse(io)).status);
    try std.testing.expect(empty.session != null);

    var missing = try testService(&.{"/definitely/not/a/telar-engine"}, 1000, 60_000);
    defer missing.deinit(io);
    missing.handle(io, .{ .prompt = prompt });
    try std.testing.expectEqual(types.Status.unavailable, (try missing.receiveResponse(io)).status);
    try std.testing.expect(!missing.child_alive.load(.acquire));
}

test "the ring refuses requests beyond its capacity and the loop drains it" {
    const io = std.testing.io;
    var service = try testService(&.{ "/bin/sh", "-c", fakes.fake_engine }, 5000, 60_000);
    defer service.deinit(io);

    const prompt = try Prompt.init(fakes.purpose, "Create a title");
    for (0..types.max_pending_requests) |_| try std.testing.expect(service.submit(io, .{ .prompt = prompt }));
    try std.testing.expect(!service.submit(io, .{ .prompt = prompt }));

    var worker = try io.concurrent(Service.run, .{ &service, io });
    for (0..types.max_pending_requests) |_| {
        try std.testing.expectEqual(types.Status.success, (try service.receiveResponse(io)).status);
    }

    service.stop(io);
    _ = worker.await(io) catch {};
    try std.testing.expect(!service.submit(io, .idle_check));
    try std.testing.expectError(error.Closed, service.receiveResponse(io));
}
