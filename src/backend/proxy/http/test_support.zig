const std = @import("std");
const tls = @import("../tls.zig");

const max_output_bytes = 64 * 1024;

pub const FakeSession = struct {
    child_input: []const u8 = "",
    origin_input: []const u8 = "",
    child_offset: usize = 0,
    origin_offset: usize = 0,
    max_read_bytes: usize = std.math.maxInt(usize),
    child_output: [max_output_bytes]u8 = undefined,
    child_output_len: usize = 0,
    origin_output: [max_output_bytes]u8 = undefined,
    origin_output_len: usize = 0,

    pub fn read(fake: *FakeSession, side: tls.Session.Side, buffer: []u8) ?usize {
        const input, const offset = switch (side) {
            .child => .{ fake.child_input, &fake.child_offset },
            .origin => .{ fake.origin_input, &fake.origin_offset },
        };
        if (offset.* == input.len) {
            return null;
        }

        const available = @min(buffer.len, input.len - offset.*);
        const take = @min(available, fake.max_read_bytes);
        @memcpy(buffer[0..take], input[offset.*..][0..take]);
        offset.* += take;
        return take;
    }

    pub fn writeAll(fake: *FakeSession, side: tls.Session.Side, bytes: []const u8) bool {
        const output, const len = switch (side) {
            .child => .{ &fake.child_output, &fake.child_output_len },
            .origin => .{ &fake.origin_output, &fake.origin_output_len },
        };
        if (bytes.len > output.len - len.*) {
            return false;
        }
        @memcpy(output[len.*..][0..bytes.len], bytes);
        len.* += bytes.len;
        return true;
    }

    pub fn childOutput(fake: *const FakeSession) []const u8 {
        return fake.child_output[0..fake.child_output_len];
    }

    pub fn originOutput(fake: *const FakeSession) []const u8 {
        return fake.origin_output[0..fake.origin_output_len];
    }
};
