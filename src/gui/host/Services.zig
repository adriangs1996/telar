//! Window-thread requests with owned payloads and exact completion identity.
//! Backend callbacks only drain requests; native results reenter the input queue.
const event = @import("../input/event.zig");
const std = @import("std");
const native = @import("../native/native.zig");
const Result = @import("../input/ClipboardResult.zig");
const Request = @import("Request.zig");
const Owner = @import("Owner.zig");
const core = @import("telar-core");
const Services = @This();

/// Clipboard reads and writes queued for the native host at once.
pub const capacity = 4;
pub const limit = core.Limit.declare("gui.host.requests", "host requests", capacity);
requests: [capacity]Request = @splat(.{}),
/// One payload of `event.max_text_bytes` per request, reserved once by
/// `init` and written only by the bytes a write copies, so an idle payload
/// costs no resident memory. Without them, as a widget's own fallback
/// services, writes are refused.
payloads: []u8 = &.{},
/// Queued copies a newer copy replaced because every request was taken:
/// the clipboard keeps the newest, and the window reports `limit`.
superseded: u64 = 0,
next_id: u64 = 1,

/// Reserves the write payloads where the services live, without writing them.
/// Example: `try gui.host.init(gpa);`
pub fn init(self: *Services, gpa: std.mem.Allocator) !void {
    self.* = .{
        .payloads = try gpa.alloc(u8, capacity * event.max_text_bytes),
    };
}

/// Example: `gui.host.deinit(gpa);`
pub fn deinit(self: *Services, gpa: std.mem.Allocator) void {
    gpa.free(self.payloads);
    self.payloads = &.{};
}

/// A delayed read keeps its original destination. Example: `try host.read(owner);`
pub fn read(self: *Services, owner: Owner) !u64 {
    const request = try self.reserve(.read);
    request.owner = owner;
    return request.id;
}

/// Example: `try host.write(selected_utf8);`
pub fn write(self: *Services, bytes: []const u8) !u64 {
    return self.writeOwned(.{}, bytes);
}

/// Correlates a write with the editor awaiting its outcome, for transactional
/// cut. Example: `const request_id = try host.writeOwned(owner, selection);`
pub fn writeOwned(self: *Services, owner: Owner, bytes: []const u8) !u64 {
    if (bytes.len > event.max_text_bytes) {
        return error.ClipboardTooLarge;
    }

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return error.InvalidUtf8;
    }

    if (self.payloads.len == 0) {
        return error.HostRequestsFull;
    }

    const request = self.reserve(.write) catch |err| request: {
        if (err != error.HostRequestsFull) {
            return err;
        }

        // A copy past a full queue keeps the newest: it takes the place of
        // the oldest copy still waiting that nothing awaits.
        const replaced = self.oldestPlainWrite() orelse return err;
        self.superseded += 1;
        replaced.state = .free;
        break :request try self.reserve(.write);
    };
    request.owner = owner;
    @memcpy(self.payloadBytes(request)[0..bytes.len], bytes);
    request.len = bytes.len;
    return request.id;
}

/// Bytes stay valid until the matching completion; the host must copy before
/// returning control. Example: `if (host.next(out)) startNativeRequest(out.*);`
pub fn next(self: *Services, out: *native.HostRequest) bool {
    var oldest: ?*Request = null;
    for (&self.requests) |*request| {
        if (request.state == .queued and (oldest == null or request.id < oldest.?.id)) {
            oldest = request;
        }
    }

    const request = oldest orelse return false;
    request.state = .active;
    out.* = .{
        .kind = @intFromEnum(request.kind),
        .request_id = request.id,
        .target_id = request.owner.target_id,
        .generation = request.owner.generation,
        .text = if (request.kind == .write and request.len != 0) self.payloadBytes(request).ptr else null,
        .len = request.len,
    };
    return true;
}

/// Unknown, duplicate and mismatched results cannot complete another request.
/// Example: `if (host.complete(result) == .read) deliverToWidget(result);`
pub fn complete(self: *Services, result: Result) ?Request.Kind {
    for (&self.requests) |*request| {
        if (request.state != .active or request.id != result.request_id or request.owner.target_id != result.target_id or request.owner.generation != result.generation) {
            continue;
        }

        request.state = .free;
        return request.kind;
    }

    return null;
}

fn reserve(self: *Services, kind: Request.Kind) !*Request {
    if (self.next_id == std.math.maxInt(u64)) {
        return error.HostRequestIdsExhausted;
    }

    for (&self.requests) |*request| {
        if (request.state != .free) {
            continue;
        }

        request.state = .queued;
        request.kind = kind;
        request.id = self.next_id;
        request.owner = .{};
        request.len = 0;
        self.next_id += 1;
        return request;
    }

    return error.HostRequestsFull;
}

fn oldestPlainWrite(self: *Services) ?*Request {
    var oldest: ?*Request = null;
    for (&self.requests) |*request| {
        if (request.state != .queued or request.kind != .write or request.owner.target_id != 0) {
            continue;
        }

        if (oldest == null or request.id < oldest.?.id) {
            oldest = request;
        }
    }

    return oldest;
}

/// The payload of a request: the one at its own index in `payloads`.
fn payloadBytes(self: *const Services, request: *const Request) []u8 {
    const index = (@intFromPtr(request) - @intFromPtr(&self.requests)) / @sizeOf(Request);
    return self.payloads[index * event.max_text_bytes ..][0..event.max_text_bytes];
}

test "host request owns writes and matches reads by request and original owner" {
    var services: Services = .{};
    try services.init(std.testing.allocator);
    defer services.deinit(std.testing.allocator);
    const read_id = try services.read(.{ .target_id = 3, .generation = 7 });
    var bytes = [_]u8{ 'o', 'k' };
    const write_id = try services.write(&bytes);
    @memset(&bytes, 'x');
    var request: native.HostRequest = .{};
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(read_id, request.request_id);
    try std.testing.expect(services.complete(.{
        .request_id = read_id,
        .target_id = 3,
        .generation = 8,
        .status = .success,
    }) == null);
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(write_id, request.request_id);
    try std.testing.expectEqualStrings("ok", request.text.?[0..request.len]);
    try std.testing.expectEqual(Request.Kind.read, services.complete(.{
        .request_id = read_id,
        .target_id = 3,
        .generation = 7,
        .status = .cancelled,
    }).?);
    try std.testing.expect(services.complete(.{
        .request_id = read_id,
        .target_id = 3,
        .generation = 7,
        .status = .success,
    }) == null);
}

test "a copy past a full queue replaces the oldest waiting copy, never an owned one" {
    var services: Services = .{};
    try services.init(std.testing.allocator);
    defer services.deinit(std.testing.allocator);
    const owned = try services.writeOwned(.{ .target_id = 4, .generation = 1 }, "cut");
    _ = try services.write("one");
    _ = try services.write("two");
    _ = try services.read(.{});
    const newest = try services.write("three");
    try std.testing.expectEqual(@as(u64, 1), services.superseded);

    var request: native.HostRequest = .{};
    var seen: [4][]const u8 = undefined;
    var ids: [4]u64 = undefined;
    for (&seen, &ids) |*text, *id| {
        try std.testing.expect(services.next(&request));
        text.* = if (request.text) |bytes| bytes[0..request.len] else "";
        id.* = request.request_id;
    }

    try std.testing.expectEqual(owned, ids[0]);
    try std.testing.expectEqualStrings("cut", seen[0]);
    try std.testing.expectEqualStrings("two", seen[1]);
    try std.testing.expectEqual(newest, ids[3]);
    try std.testing.expectEqualStrings("three", seen[3]);
    try std.testing.expectError(error.HostRequestsFull, services.read(.{}));
}
