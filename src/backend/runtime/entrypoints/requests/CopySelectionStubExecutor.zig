const StubExecutor = @This();
const copy_selection_commands = @import("../../application/commands/copy_selection.zig");
const std = @import("std");
outcome: enum { copied, pane_not_attached, unavailable, too_large } = .copied,
bytes: []const u8 = "selected",
call_count: usize = 0,
scratch_len: usize = 0,
command: ?copy_selection_commands.CopySelection = null,

pub fn execute(stub: *StubExecutor, command: copy_selection_commands.CopySelection, scratch: []u8) copy_selection_commands.CopySelectionResult {
    stub.call_count += 1;
    stub.scratch_len = scratch.len;
    stub.command = command;

    return switch (stub.outcome) {
        .copied => copied: {
            std.debug.assert(stub.bytes.len <= scratch.len);
            @memcpy(scratch[0..stub.bytes.len], stub.bytes);
            break :copied .{ .copied = scratch[0..stub.bytes.len] };
        },
        .pane_not_attached => .pane_not_attached,
        .unavailable => .unavailable,
        .too_large => .too_large,
    };
}
