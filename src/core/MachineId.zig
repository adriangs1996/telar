const std = @import("std");

/// A machine profile's stable identity: 48 random bits, written as `m-` and
/// twelve lowercase hex digits. A profile's label can change; its id never
/// does, so a window keeps a machine's connection across a rename.
pub const MachineId = enum(u64) {
    invalid = 0,
    _,

    /// Characters of the written form.
    pub const text_bytes = prefix.len + hex_digits;

    const prefix = "m-";
    const hex_digits = 12;
    const value_bits = hex_digits * 4;

    /// Draws a fresh identity from the system's secure random source.
    ///
    /// ```zig
    /// const id = try MachineId.generate(io);
    /// ```
    pub fn generate(io: std.Io) !MachineId {
        while (true) {
            var bytes: [@sizeOf(u64)]u8 = undefined;
            try io.randomSecure(&bytes);
            const value = std.mem.readInt(u64, &bytes, .little) >> (@bitSizeOf(u64) - value_bits);
            if (value != 0) {
                return @enumFromInt(value);
            }
        }
    }

    /// Reads the written form; anything else is `error.InvalidMachineId`.
    ///
    /// ```zig
    /// const id = try MachineId.parse("m-3f9c2a000001");
    /// ```
    pub fn parse(text: []const u8) !MachineId {
        if (text.len != text_bytes or !std.mem.startsWith(u8, text, prefix)) {
            return error.InvalidMachineId;
        }

        const digits = text[prefix.len..];
        for (digits) |digit| {
            if (!std.ascii.isDigit(digit) and !(digit >= 'a' and digit <= 'f')) {
                return error.InvalidMachineId;
            }
        }

        const value = std.fmt.parseUnsigned(u64, digits, 16) catch return error.InvalidMachineId;
        if (value == 0) {
            return error.InvalidMachineId;
        }

        return @enumFromInt(value);
    }

    /// Writes the id into `buffer` and returns the written form.
    ///
    /// ```zig
    /// var buffer: [MachineId.text_bytes]u8 = undefined;
    /// const text = id.format(&buffer);
    /// ```
    pub fn format(self: MachineId, buffer: *[text_bytes]u8) []const u8 {
        return std.fmt.bufPrint(buffer, prefix ++ "{x:0>12}", .{@intFromEnum(self)}) catch unreachable;
    }
};

test "a machine id round-trips through its written form" {
    const id = try MachineId.parse("m-3f9c2a00b001");
    var buffer: [MachineId.text_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("m-3f9c2a00b001", id.format(&buffer));

    const fresh = try MachineId.generate(std.testing.io);
    try std.testing.expectEqual(fresh, try MachineId.parse(fresh.format(&buffer)));
}

test "malformed machine ids are refused" {
    for ([_][]const u8{ "", "m-", "m-000000000000", "m-3F9C2A00B001", "x-3f9c2a00b001", "m-3f9c2a00b0011", "m-3f9c2a00b00g" }) |text| {
        try std.testing.expectError(error.InvalidMachineId, MachineId.parse(text));
    }
}
