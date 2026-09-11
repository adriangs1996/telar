const std = @import("std");
const OptionsType = @import("Options.zig");
const types = @import("types.zig");
const ResponseType = @import("Response.zig");
const SessionType = @import("Session.zig");
const PromptType = @import("Prompt.zig");
/// The service must live at a stable address for as long as `run` executes.
const Service = @This();

gpa: std.mem.Allocator,
options: OptionsType,
requests: std.Io.Queue(types.Request),
responses: std.Io.Queue(ResponseType),
request_storage: []types.Request,
response_storage: []ResponseType,
session: ?*SessionType = null,
child_alive: std.atomic.Value(bool) = .init(false),
idle_check_pending: std.atomic.Value(bool) = .init(false),

/// Allocates the rings. No child is started.
///
/// ```zig
/// var service = try Service.init(gpa, options);
/// defer service.deinit(io);
/// ```
pub fn init(gpa: std.mem.Allocator, options: OptionsType) !Service {
    const request_storage = try gpa.alloc(types.Request, types.max_pending_requests);
    errdefer gpa.free(request_storage);
    const response_storage = try gpa.alloc(ResponseType, types.max_pending_requests);
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
pub fn stop(service: *Service, io: std.Io) void {
    service.requests.close(io);
    service.responses.close(io);
}

/// Kills a live child and frees the rings. `run` must have returned.
///
/// ```zig
/// service.deinit(io);
/// ```
pub fn deinit(service: *Service, io: std.Io) void {
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
pub fn submit(service: *Service, io: std.Io, request: types.Request) bool {
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
pub fn requestIdleCheck(service: *Service, io: std.Io) void {
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
pub fn receiveResponse(service: *Service, io: std.Io) anyerror!ResponseType {
    return service.responses.getOne(io);
}

/// Serves requests in order until `stop` closes the ring.
///
/// ```zig
/// var worker = try io.concurrent(Service.run, .{ &service, io });
/// ```
pub fn run(service: *Service, io: std.Io) anyerror!void {
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
pub fn handle(service: *Service, io: std.Io, request: types.Request) void {
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
fn answer(service: *Service, io: std.Io, prompt: *const PromptType) ResponseType {
    var response: ResponseType = .{ .purpose = prompt.purpose, .status = .failed };
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

fn ensureSession(service: *Service, io: std.Io) !*SessionType {
    if (service.session) |session| {
        return session;
    }

    const session = try SessionType.open(io, service.gpa, service.options);
    service.session = session;
    service.child_alive.store(true, .release);
    return session;
}

fn closeSession(service: *Service, io: std.Io) void {
    const session = service.session orelse return;
    service.session = null;
    service.child_alive.store(false, .release);
    session.close(io);
}
