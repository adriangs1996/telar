//! Replies a terminal sends a program about one of its graphics commands.

const std = @import("std");
const command = @import("command.zig");

/// The POSIX-style error names the Kitty protocol replies with.
pub const ErrorCode = enum { ENOMEM, EINVAL, ENOENT, EBADF };

/// Reports that the command for `image_id` failed, with a fixed human
/// detail. The detail is known at compile time and may hold no control
/// bytes, so a reply can never carry an escape sequence of its own.
/// For example: `_ = try writeError(writer, image_id, .ENOMEM, "graphics upload limit exceeded")`.
pub fn writeError(writer: *std.Io.Writer, image_id: u32, code: ErrorCode, comptime detail: []const u8) std.Io.Writer.Error!usize {
    comptime {
        for (detail) |byte| {
            if (byte < ' ' or byte == del) {
                @compileError("a reply detail holds no control bytes");
            }
        }
    }

    const head = try command.print(writer, "\x1b_Gi={d};{s}: ", .{ image_id, @tagName(code) });
    try writer.writeAll(detail ++ terminator);
    return head + detail.len + terminator.len;
}

const del = 0x7f;
const terminator = "\x1b\\";
