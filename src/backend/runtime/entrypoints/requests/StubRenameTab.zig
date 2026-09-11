const StubRenameTab = @This();
const rename_tab_commands = @import("../../application/commands/rename_tab.zig");
const source_namespace = @import("rename_tab.zig");
const std = @import("std");
result: ?rename_tab_commands.RenameTabResult = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?source_namespace.schema.TabLocation = null,
last_label: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
last_label_len: u8 = 0,

pub fn executor(stub: *StubRenameTab) rename_tab_commands.RenameTabExecutor {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: rename_tab_commands.RenameTab) anyerror!rename_tab_commands.RenameTabResult {
    const stub: *StubRenameTab = @ptrCast(@alignCast(context));
    std.debug.assert(command.label.len <= stub.last_label.len);

    stub.call_count += 1;
    stub.last_location = command.location;
    stub.last_label_len = @intCast(command.label.len);
    @memcpy(stub.last_label[0..command.label.len], command.label);

    if (stub.failure) |failure| {
        return failure;
    }

    return stub.result.?;
}

pub fn lastLabel(stub: *const StubRenameTab) []const u8 {
    return stub.last_label[0..stub.last_label_len];
}
