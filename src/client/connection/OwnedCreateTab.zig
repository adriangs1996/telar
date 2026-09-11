const RequestIdType = @import("telar-core").RequestId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LaunchType = @import("telar-core").Launch;
const CreateTabType = @import("telar-core").CreateTab;
const OwnedCreateTab = @This();

pub const max_owned_arguments = 8;
const max_owned_argument_bytes = 224;

request_id: RequestIdType,
workspace: WorkspaceLocationType,
label: [max_tab_label_bytes_module]u8 = undefined,
label_len: u8,
size: TerminalSizeType,
launch: LaunchType,
/// NUL-free bytes of a bounded owned argv; zero count borrows
/// `launch.arguments`, which is only safe for process-lifetime slices.
argument_storage: [max_owned_argument_bytes]u8 = undefined,
argument_lens: [max_owned_arguments]u8 = undefined,
argument_count: u8 = 0,

pub fn ownArguments(value: *OwnedCreateTab, arguments: []const []const u8) bool {
    if (arguments.len == 0 or arguments.len > max_owned_arguments) {
        return false;
    }
    var total: usize = 0;
    for (arguments) |argument| total += argument.len;
    if (total > max_owned_argument_bytes) {
        return false;
    }

    var offset: usize = 0;
    for (arguments, 0..) |argument, index| {
        @memcpy(value.argument_storage[offset .. offset + argument.len], argument);
        value.argument_lens[index] = @intCast(argument.len);
        offset += argument.len;
    }
    value.argument_count = @intCast(arguments.len);
    return true;
}

pub fn view(value: *const OwnedCreateTab, cwd: []const u8, scratch: *[max_owned_arguments][]const u8) CreateTabType {
    var launch = value.launch;
    launch.cwd = cwd;
    if (value.argument_count != 0) {
        var offset: usize = 0;
        for (0..value.argument_count) |index| {
            const len = value.argument_lens[index];
            scratch[index] = value.argument_storage[offset .. offset + len];
            offset += len;
        }
        launch.arguments = scratch[0..value.argument_count];
    }

    return .{
        .request_id = value.request_id,
        .workspace = value.workspace,
        .label = value.label[0..value.label_len],
        .size = value.size,
        .launch = launch,
    };
}
