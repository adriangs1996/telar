const TabRenamed = @import("../../../workspace/TabRenamed.zig");
const TabLocationType = @import("telar-core").TabLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const RenameTabExecutorType = @import("../../application/commands/RenameTabExecutor.zig");
const RenameTabType = @import("../../application/commands/RenameTab.zig");
const std = @import("std");
const StubRenameTab = @This();

result: ?TabRenamed = null,
failure: ?anyerror = null,
call_count: usize = 0,
last_location: ?TabLocationType = null,
last_label: [max_tab_label_bytes_module]u8 = undefined,
last_label_len: u8 = 0,

pub fn executor(stub: *StubRenameTab) RenameTabExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: RenameTabType) anyerror!TabRenamed {
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
