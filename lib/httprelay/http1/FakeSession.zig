const std = @import("std");
const test_support = @import("test_support.zig");
const localca = @import("localca");
const Session = localca.Session;
const FakeSession = @This();

child_input: []const u8 = "",
origin_input: []const u8 = "",
child_offset: usize = 0,
origin_offset: usize = 0,
max_read_bytes: usize = std.math.maxInt(usize),
child_output: [test_support.max_output_bytes]u8 = undefined,
child_output_len: usize = 0,
origin_output: [test_support.max_output_bytes]u8 = undefined,
origin_output_len: usize = 0,
write_calls: usize = 0,
fail_write_at: ?usize = null,

pub fn read(self: *FakeSession, side: Session.Side, buffer: []u8) ?usize {
    const input, const offset = switch (side) {
        .child => .{ self.child_input, &self.child_offset },
        .origin => .{ self.origin_input, &self.origin_offset },
    };
    if (offset.* == input.len) {
        return null;
    }

    const available = @min(buffer.len, input.len - offset.*);
    const take = @min(available, self.max_read_bytes);
    @memcpy(buffer[0..take], input[offset.*..][0..take]);
    offset.* += take;
    return take;
}

pub fn writeAll(self: *FakeSession, side: Session.Side, bytes: []const u8) bool {
    const index = self.write_calls;
    self.write_calls += 1;
    if (self.fail_write_at == index) {
        return false;
    }

    const output, const len = switch (side) {
        .child => .{ &self.child_output, &self.child_output_len },
        .origin => .{ &self.origin_output, &self.origin_output_len },
    };
    if (bytes.len > output.len - len.*) {
        return false;
    }
    @memcpy(output[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

pub fn childOutput(self: *const FakeSession) []const u8 {
    return self.child_output[0..self.child_output_len];
}

pub fn originOutput(self: *const FakeSession) []const u8 {
    return self.origin_output[0..self.origin_output_len];
}
