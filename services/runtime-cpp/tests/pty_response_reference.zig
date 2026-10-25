const std = @import("std");
const Queue = @import("reference/pane/PtyResponseQueue.zig");

const Operation = extern struct {
    kind: u32,
    bytes: [*]const u8,
    length: usize,
};

export fn evaluate(operations: [*]const Operation, count: usize, output: [*]u8) usize {
    var queue: Queue = .{};
    var written: usize = 0;
    for (operations[0..count]) |operation| {
        var accepted = true;
        switch (operation.kind) {
            0 => accepted = queue.push(operation.bytes[0..operation.length]),
            1 => if (queue.peek() != null) {
                queue.pop();
            },
            2 => queue.clear(),
            else => unreachable,
        }

        const response = queue.peek();
        const bytes = response orelse &.{};
        output[written] = @intFromBool(accepted);
        output[written + 1] = queue.len;
        output[written + 2] = @intFromBool(response != null);
        std.mem.writeInt(u64, output[written + 3 ..][0..8], queue.dropped, .little);
        std.mem.writeInt(u16, output[written + 11 ..][0..2], @intCast(bytes.len), .little);
        @memcpy(output[written + 13 ..][0..bytes.len], bytes);
        written += 13 + bytes.len;
    }
    return written;
}
