const core = @import("telar-core");
const OwnedArguments = @import("OwnedArguments.zig");
const OwnedCreateTab = @This();

request_id: core.RequestId,
workspace: core.WorkspaceLocation,
label: [core.max_tab_label_bytes]u8 = undefined,
label_len: u8,
size: core.TerminalSize,
launch: core.Launch,
arguments: OwnedArguments = .{},

/// Owns transient command arguments before configuration can be replaced.
/// Example: `try pending.ownArguments(slot_bytes);`
pub fn ownArguments(self: *OwnedCreateTab, bytes: []u8) !void {
    self.arguments = try OwnedArguments.copy(self.launch.arguments, bytes);
    self.launch.arguments = &.{};
}

/// Borrows owned launch arguments while encoding one request.
/// Example: `const request = pending.view(slot_bytes, &scratch);`
pub fn view(self: *const OwnedCreateTab, bytes: []const u8, scratch: *[core.max_argument_count][]const u8) core.CreateTab {
    var launch = self.launch;
    launch.arguments = self.arguments.view(bytes, scratch);

    return .{
        .request_id = self.request_id,
        .workspace = self.workspace,
        .label = self.label[0..self.label_len],
        .size = self.size,
        .launch = launch,
    };
}
