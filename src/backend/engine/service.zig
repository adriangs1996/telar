/// The service must live at a stable address for as long as `run` executes.
const Service = @This();
const std = @import("std");
const source_namespace = @import("service_support.zig");
const types = @import("types.zig");
gpa: std.mem.Allocator,
options: source_namespace.Options,
requests: source_namespace.Io.Queue(source_namespace.Request),
responses: source_namespace.Io.Queue(source_namespace.Response),
request_storage: []source_namespace.Request,
response_storage: []source_namespace.Response,
session: ?*source_namespace.Session = null,
child_alive: std.atomic.Value(bool) = .init(false),
idle_check_pending: std.atomic.Value(bool) = .init(false),

/// Allocates the rings. No child is started.
///
/// ```zig
/// var service = try Service.init(gpa, options);
/// defer service.deinit(io);
/// ```
pub fn init(gpa: std.mem.Allocator, options: source_namespace.Options) !Service {
    const request_storage = try gpa.alloc(source_namespace.Request, types.max_pending_requests);
    errdefer gpa.free(request_storage);
    const response_storage = try gpa.alloc(source_namespace.Response, types.max_pending_requests);
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
pub fn stop(service: *Service, io: source_namespace.Io) void {
    service.requests.close(io);
    service.responses.close(io);
}

/// Kills a live child and frees the rings. `run` must have returned.
///
/// ```zig
/// service.deinit(io);
/// ```
pub fn deinit(service: *Service, io: source_namespace.Io) void {
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
pub fn submit(service: *Service, io: source_namespace.Io, request: source_namespace.Request) bool {
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
pub fn requestIdleCheck(service: *Service, io: source_namespace.Io) void {
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
pub fn receiveResponse(service: *Service, io: source_namespace.Io) anyerror!source_namespace.Response {
    return service.responses.getOne(io);
}

/// Serves requests in order until `stop` closes the ring.
///
/// ```zig
/// var worker = try io.concurrent(Service.run, .{ &service, io });
/// ```
pub fn run(service: *Service, io: source_namespace.Io) anyerror!void {
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
pub fn handle(service: *Service, io: source_namespace.Io, request: source_namespace.Request) void {
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
fn answer(service: *Service, io: source_namespace.Io, prompt: *const source_namespace.Prompt) source_namespace.Response {
    var response: source_namespace.Response = .{ .purpose = prompt.purpose, .status = .failed };
    const session = service.ensureSession(io) catch |err| {
        response.status = if (err == error.FileNotFound) .unavailable else .failed;
        return response;
    };

    response.status = session.ask(io, .{ .prompt = prompt.slice(), .response = &response });
    session.touch(io);

    switch (response.status) {
        .success, .invalid_output => {},
        .unavailable, .timeout, .failed => service.closeSession(io),
    }

    return response;
}

fn ensureSession(service: *Service, io: source_namespace.Io) !*source_namespace.Session {
    if (service.session) |session| {
        return session;
    }

    const session = try source_namespace.Session.open(io, service.gpa, service.options);
    service.session = session;
    service.child_alive.store(true, .release);
    return session;
}

fn closeSession(service: *Service, io: source_namespace.Io) void {
    const session = service.session orelse return;
    service.session = null;
    service.child_alive.store(false, .release);
    session.close(io);
}
