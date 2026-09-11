//! The engine actor: bounded request and response rings around one
//! sequential worker that owns at most one child session.
//!
//! Requests queue behind the actor, the child starts on the first prompt,
//! and it is killed after an idle interval or on any protocol failure so
//! the next prompt starts a fresh process.

const std = @import("std");
const session_mod = @import("session_support.zig");
const types = @import("types.zig");

pub const Io = std.Io;
pub const Options = types.Options;
pub const Prompt = types.Prompt;
pub const Request = types.Request;
pub const Response = types.Response;
pub const Session = session_mod.Session;

pub const Service = @import("Service.zig");

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
