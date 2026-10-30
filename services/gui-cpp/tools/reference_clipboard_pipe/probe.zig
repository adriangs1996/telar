const std = @import("std");
const Source = @import("window/linux/ClipboardSource.zig");
const native = @import("window/native.zig");
const c = native.c;

fn limit(name: [*:0]const u8) !usize {
    const value = c.getenv(name) orelse return error.MissingLimit;

    return std.fmt.parseInt(usize, std.mem.span(value), 10);
}

fn write(bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = c.write(1, bytes.ptr + written, bytes.len - written);
        if (count <= 0) {
            return error.WriteFailed;
        }

        written += @intCast(count);
    }
}

pub fn main() !void {
    const source: Source = .{ .fd = 0 };
    const bytes = source.read(std.heap.page_allocator, .{
        .source_bytes = try limit("PIPE_SOURCE_LIMIT"),
        .png_bytes = try limit("PIPE_PNG_LIMIT"),
        .pixels = 0,
    }) catch |failure| {
        try write(@errorName(failure));
        try write("\n");

        return;
    };
    defer std.heap.page_allocator.free(bytes);
    try write("ok\n");
    try write(bytes);
}
