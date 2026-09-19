const RequestIdType = @import("telar-core").RequestId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchType = @import("telar-core").Launch;
const CreateTabType = @import("telar-core").CreateTab;
const OwnedArguments = @import("OwnedArguments.zig");
const max_argument_count = @import("telar-core").max_argument_count;
const OwnedCreateTab = @This();

request_id: RequestIdType,
kind: @import("telar-core").PaneKind = .terminal,
workspace: WorkspaceLocationType,
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8,
size: TerminalSizeType,
launch: LaunchType,
arguments: OwnedArguments = .{},

/// Owns transient command arguments before configuration can be replaced.
/// Example: `try pending.ownArguments(slot_bytes);`
pub fn ownArguments(self: *OwnedCreateTab, bytes: []u8) !void {
    self.arguments = try OwnedArguments.copy(self.launch.arguments, bytes);
    self.launch.arguments = &.{};
}

/// Borrows owned launch arguments while encoding one request.
/// Example: `const request = pending.view(slot_bytes, &scratch);`
pub fn view(self: *const OwnedCreateTab, bytes: []const u8, scratch: *[max_argument_count][]const u8) CreateTabType {
    var launch = self.launch;
    launch.arguments = self.arguments.view(bytes, scratch);

    return .{
        .kind = self.kind,
        .request_id = self.request_id,
        .workspace = self.workspace,
        .label = self.label[0..self.label_len],
        .size = self.size,
        .launch = launch,
    };
}
