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
/// Writes whose bytes wait for the host at once. The host copies a write
/// when it takes it, so two cover a copy that lands while another waits.
pub const write_slots = 2;

requests: [capacity]Request = @splat(.{}),
/// `write_slots` payloads of `event.max_text_bytes`, reserved once by `init`
/// and written only by the bytes a write copies. Without them, as a widget's
/// own fallback services, writes are refused.
payloads: []u8 = &.{},
payload_used: [write_slots]bool = @splat(false),
next_id: u64 = 1,

/// Reserves the write payloads where the services live, without writing them.
/// Example: `try gui.host.init(gpa);`
pub fn init(self: *Services, gpa: std.mem.Allocator) !void {
    self.* = .{
        .payloads = try gpa.alloc(u8, write_slots * event.max_text_bytes),
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

    const payload = self.freePayload() orelse return error.HostRequestsFull;
    const request = try self.reserve(.write);
    request.owner = owner;
    request.payload = payload;
    self.payload_used[payload] = true;
    @memcpy(self.payloadBytes(payload)[0..bytes.len], bytes);
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
        .text = if (request.payload) |payload| if (request.len == 0) null else self.payloadBytes(payload).ptr else null,
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
        if (request.payload) |payload| {
            self.payload_used[payload] = false;
            request.payload = null;
        }

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
        request.payload = null;
        request.len = 0;
        self.next_id += 1;
        return request;
    }

    return error.HostRequestsFull;
}

fn freePayload(self: *const Services) ?u8 {
    if (self.payloads.len == 0) {
        return null;
    }

    for (self.payload_used, 0..) |used, index| {
        if (!used) {
            return @intCast(index);
        }
    }

    return null;
}

fn payloadBytes(self: *const Services, payload: u8) []u8 {
    return self.payloads[@as(usize, payload) * event.max_text_bytes ..][0..event.max_text_bytes];
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

test "writes share two payloads and a third waits for one to complete" {
    var services: Services = .{};
    try services.init(std.testing.allocator);
    defer services.deinit(std.testing.allocator);
    const first = try services.write("one");
    _ = try services.write("two");
    try std.testing.expectError(error.HostRequestsFull, services.write("three"));
    _ = try services.read(.{});
    var request: native.HostRequest = .{};
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(first, request.request_id);
    try std.testing.expect(services.complete(.{
        .request_id = first,
        .target_id = 0,
        .generation = 0,
        .status = .success,
    }) != null);
    const third = try services.write("three");
    try std.testing.expect(services.next(&request));
    try std.testing.expect(services.next(&request));
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(third, request.request_id);
    try std.testing.expectEqualStrings("three", request.text.?[0..request.len]);
}
