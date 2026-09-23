const std = @import("std");
const Options = @import("Options.zig");
const types = @import("types.zig");
const Response = @import("Response.zig");
const Session = @import("Session.zig");
const Prompt = @import("Prompt.zig");
/// The service must live at a stable address for as long as `run` executes.
const Service = @This();

gpa: std.mem.Allocator,
options: Options,
requests: std.Io.Queue(types.Request),
responses: std.Io.Queue(Response),
request_storage: []types.Request,
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
    const request_storage = try gpa.alloc(types.Request, types.max_pending_requests);
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
pub fn stop(self: *Service, io: std.Io) void {
    self.requests.close(io);
    self.responses.close(io);
}

/// Kills a live child and frees the rings. `run` must have returned.
///
/// ```zig
/// service.deinit(io);
/// ```
pub fn deinit(self: *Service, io: std.Io) void {
    self.responses.close(io);
    self.closeSession(io);
    self.gpa.free(self.request_storage);
    self.gpa.free(self.response_storage);
}

/// Queues one request without blocking. Returns false when the ring is
/// full or closed; the caller decides whether that is a failure.
///
/// ```zig
/// if (!service.submit(io, .{ .prompt = prompt })) return error.EngineBusy;
/// ```
pub fn submit(self: *Service, io: std.Io, request: types.Request) bool {
    const queued = self.requests.put(io, &.{request}, 0) catch return false;
    return queued == 1;
}

/// Asks the actor to kill an idle child. Cheap to call on every
/// maintenance tick: it queues nothing while no child is alive or while
/// a check is already pending.
///
/// ```zig
/// service.requestIdleCheck(io);
/// ```
pub fn requestIdleCheck(self: *Service, io: std.Io) void {
    if (!self.child_alive.load(.acquire)) {
        return;
    }

    if (self.idle_check_pending.swap(true, .acq_rel)) {
        return;
    }

    if (!self.submit(io, .idle_check)) {
        self.idle_check_pending.store(false, .release);
    }
}

/// Waits for the next reply. Fails once the service is stopped.
///
/// ```zig
/// const response = try service.receiveResponse(io);
/// ```
pub fn receiveResponse(self: *Service, io: std.Io) anyerror!Response {
    return self.responses.getOne(io);
}

/// Serves requests in order until `stop` closes the ring.
///
/// ```zig
/// var worker = try io.concurrent(Service.run, .{ &service, io });
/// ```
pub fn run(self: *Service, io: std.Io) anyerror!void {
    while (true) {
        const request = self.requests.getOne(io) catch return;
        self.handle(io, request);
    }
}

/// Applies one request on the actor. Public so tests drive the actor
/// synchronously; `run` is this in a loop.
///
/// ```zig
/// service.handle(io, .idle_check);
/// ```
pub fn handle(self: *Service, io: std.Io, request: types.Request) void {
    switch (request) {
        .idle_check => {
            self.idle_check_pending.store(false, .release);
            const session = self.session orelse return;
            if (session.idleMs(io) >= self.options.idle_timeout_ms) {
                self.closeSession(io);
            }
        },
        .prompt => |*prompt| {
            const response = self.answer(io, prompt);
            self.responses.putOne(io, response) catch {};
        },
    }
}

/// Answers on the live child, or a fresh one. A child that timed out or
/// broke the protocol is discarded; one that merely answered badly is
/// kept, because its next reply may be fine.
fn answer(self: *Service, io: std.Io, prompt: *const Prompt) Response {
    var response: Response = .{ .purpose = prompt.purpose, .status = .failed };
    const session = self.ensureSession(io) catch |err| {
        response.status = if (err == error.FileNotFound) .unavailable else .failed;
        return response;
    };

    response.status = session.ask(io, .{ .prompt = prompt.slice(), .response = &response });
    session.touch(io);

    switch (response.status) {
        .success, .invalid_output => {},
        .unavailable, .timeout, .failed => self.closeSession(io),
    }

    return response;
}

fn ensureSession(self: *Service, io: std.Io) !*Session {
    if (self.session) |session| {
        return session;
    }

    const session = try Session.open(io, self.gpa, self.options);
    self.session = session;
    self.child_alive.store(true, .release);
    return session;
}

fn closeSession(self: *Service, io: std.Io) void {
    const session = self.session orelse return;
    self.session = null;
    self.child_alive.store(false, .release);
    session.close(io);
}
