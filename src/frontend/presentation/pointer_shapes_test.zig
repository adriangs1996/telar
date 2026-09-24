const console = @import("console");
const core = @import("telar-core");
const std = @import("std");

test "every wire pointer shape has a bounded CSS sequence" {
    inline for (std.meta.tags(core.PointerShape)) |shape| {
        const encoded = console.pointer.sequence(shape);
        try std.testing.expect(std.mem.startsWith(u8, encoded, "\x1b]22;"));
        try std.testing.expect(std.mem.endsWith(u8, encoded, "\x1b\\"));
        try std.testing.expect(encoded.len <= 20);

        for (encoded[5 .. encoded.len - 2]) |byte| {
            try std.testing.expect(std.ascii.isLower(byte) or byte == '-');
        }
    }

    try std.testing.expectEqualStrings(console.sequences.reset_pointer, console.pointer.sequence(core.PointerShape.default));
}
