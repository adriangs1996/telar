//! Window-thread requests with owned payloads and exact completion identity.
//! Backend callbacks only drain requests; native results reenter the input queue.
const std = @import("std");
const native = @import("../native/native.zig");
const Result = @import("../input/ClipboardResult.zig");
const Request = @import("Request.zig");
const Owner = @import("Owner.zig");
const Services = @This();

requests: [4]Request = @splat(.{}),
next_id: u64 = 1,

/// A delayed read keeps its original destination. Example: `try host.read(owner);`
pub fn read(services: *Services, owner: Owner) !u64 {
    const request = try services.reserve(.read);
    request.owner = owner;
    return request.id;
}

/// Example: `try host.write(selected_utf8);`
pub fn write(services: *Services, bytes: []const u8) !u64 {
    return services.writeOwned(.{}, bytes);
}

/// Correlates a write with the editor awaiting its outcome, for transactional
/// cut. Example: `const request_id = try host.writeOwned(owner, selection);`
pub fn writeOwned(services: *Services, owner: Owner, bytes: []const u8) !u64 {
    if (bytes.len > @import("../input/event.zig").max_text_bytes) {
        return error.ClipboardTooLarge;
    }

    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return error.InvalidUtf8;
    }

    const request = try services.reserve(.write);
    request.owner = owner;
    @memcpy(request.bytes[0..bytes.len], bytes);
    request.len = bytes.len;
    return request.id;
}

/// Bytes stay valid until the matching completion; the host must copy before
/// returning control. Example: `if (host.next(out)) startNativeRequest(out.*);`
pub fn next(services: *Services, out: *native.HostRequest) bool {
    var oldest: ?*Request = null;
    for (&services.requests) |*request| {
        if (request.state == .queued and (oldest == null or request.id < oldest.?.id)) {
            oldest = request;
        }
    }

    const request = oldest orelse return false;
    request.state = .active;
    out.* = .{ .kind = @intFromEnum(request.kind), .request_id = request.id, .target_id = request.owner.target_id, .generation = request.owner.generation, .text = if (request.len == 0) null else &request.bytes, .len = request.len };
    return true;
}

/// Unknown, duplicate and mismatched results cannot complete another request.
/// Example: `if (host.complete(result) == .read) deliverToWidget(result);`
pub fn complete(services: *Services, result: Result) ?Request.Kind {
    for (&services.requests) |*request| {
        if (request.state != .active or request.id != result.request_id or request.owner.target_id != result.target_id or request.owner.generation != result.generation) {
            continue;
        }

        request.state = .free;
        return request.kind;
    }

    return null;
}

fn reserve(services: *Services, kind: Request.Kind) !*Request {
    if (services.next_id == std.math.maxInt(u64)) {
        return error.HostRequestIdsExhausted;
    }

    for (&services.requests) |*request| {
        if (request.state != .free) {
            continue;
        }

        request.state = .queued;
        request.kind = kind;
        request.id = services.next_id;
        request.owner = .{};
        request.len = 0;
        services.next_id += 1;
        return request;
    }

    return error.HostRequestsFull;
}

test "host request owns writes and matches reads by request and original owner" {
    var services: Services = .{};
    const read_id = try services.read(.{ .target_id = 3, .generation = 7 });
    var bytes = [_]u8{ 'o', 'k' };
    const write_id = try services.write(&bytes);
    @memset(&bytes, 'x');
    var request: native.HostRequest = .{};
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(read_id, request.request_id);
    try std.testing.expect(services.complete(.{ .request_id = read_id, .target_id = 3, .generation = 8, .status = .success }) == null);
    try std.testing.expect(services.next(&request));
    try std.testing.expectEqual(write_id, request.request_id);
    try std.testing.expectEqualStrings("ok", request.text.?[0..request.len]);
    try std.testing.expectEqual(Request.Kind.read, services.complete(.{ .request_id = read_id, .target_id = 3, .generation = 7, .status = .cancelled }).?);
    try std.testing.expect(services.complete(.{ .request_id = read_id, .target_id = 3, .generation = 7, .status = .success }) == null);
}
