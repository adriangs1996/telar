const FakeSession = @This();
const tls = @import("../tls.zig");
child_input: []const u8,
origin_input: []const u8,
child_offset: usize = 0,
origin_offset: usize = 0,
child_output: [128]u8 = undefined,
child_output_len: usize = 0,
origin_output: [128]u8 = undefined,
origin_output_len: usize = 0,
child_half_closed: bool = false,
origin_half_closed: bool = false,

pub fn read(session: *FakeSession, side: tls.Session.Side, output: []u8) ?usize {
    const input, const offset = switch (side) {
        .child => .{ session.child_input, &session.child_offset },
        .origin => .{ session.origin_input, &session.origin_offset },
    };

    if (offset.* == input.len) {
        return null;
    }

    const len = @min(output.len, input.len - offset.*);
    @memcpy(output[0..len], input[offset.*..][0..len]);
    offset.* += len;
    return len;
}

pub fn writeAll(session: *FakeSession, side: tls.Session.Side, input: []const u8) bool {
    const output, const len = switch (side) {
        .child => .{ &session.child_output, &session.child_output_len },
        .origin => .{ &session.origin_output, &session.origin_output_len },
    };

    if (input.len > output.len - len.*) {
        return false;
    }

    @memcpy(output[len.*..][0..input.len], input);
    len.* += input.len;
    return true;
}

pub fn halfClose(session: *FakeSession, side: tls.Session.Side) void {
    switch (side) {
        .child => session.child_half_closed = true,
        .origin => session.origin_half_closed = true,
    }
}

pub fn childOutput(session: *const FakeSession) []const u8 {
    return session.child_output[0..session.child_output_len];
}

pub fn originOutput(session: *const FakeSession) []const u8 {
    return session.origin_output[0..session.origin_output_len];
}
