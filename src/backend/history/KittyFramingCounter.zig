const escape_ops = @import("escape.zig");
/// Counts complete Kitty APC commands across arbitrary PTY read boundaries
/// without retaining their payload. Ghostty performs the actual parsing; this
/// recognizer exists only to enforce a bounded number of chunks in an
/// incomplete upload.
///
/// Only ESC-introduced sequences count. The emulator parses the stream as
/// UTF-8, where the raw C1 bytes 0x9f (APC) and 0x9c (ST) are ordinary
/// continuation bytes; honouring them here would let plain text ("ß" is
/// 0xC3 0x9F) desynchronize the chunk count.
const KittyFramingCounter = @This();

state: State = .normal,

const State = enum { normal, escape, apc_identify, kitty, kitty_escape, other, other_escape };

pub fn observe(counter: *KittyFramingCounter, bytes: []const u8) usize {
    var complete: usize = 0;
    for (bytes) |byte| switch (counter.state) {
        .normal => counter.state = if (byte == escape_ops.esc) .escape else .normal,
        .escape => counter.state = switch (byte) {
            '_' => .apc_identify,
            escape_ops.esc => .escape,
            else => .normal,
        },
        .apc_identify => counter.state = if (byte == 'G')
            .kitty
        else if (byte == escape_ops.esc)
            .other_escape
        else
            .other,
        .kitty => counter.state = switch (byte) {
            escape_ops.esc => .kitty_escape,
            else => .kitty,
        },
        .kitty_escape => counter.state = if (byte == '\\') state: {
            complete += 1;
            break :state .normal;
        } else if (byte == escape_ops.esc)
            .kitty_escape
        else
            .kitty,
        .other => counter.state = switch (byte) {
            escape_ops.esc => .other_escape,
            else => .other,
        },
        .other_escape => counter.state = if (byte == '\\')
            .normal
        else if (byte == escape_ops.esc)
            .other_escape
        else
            .other,
    };
    return complete;
}
