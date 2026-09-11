const RequestIdType = @import("telar-core").RequestId;
const TerminalSizeType = @import("telar-core").TerminalSize;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const LaunchType = @import("telar-core").Launch;
const CreateWorkspaceType = @import("telar-core").CreateWorkspace;
const OwnedCreateWorkspace = @This();

request_id: RequestIdType,
size: TerminalSizeType,
name: [max_tab_label_bytes_module]u8 = undefined,
name_len: u8,
launch: LaunchType,

pub fn view(value: *const OwnedCreateWorkspace, cwd: []const u8) CreateWorkspaceType {
    var launch = value.launch;
    launch.cwd = cwd;

    return .{
        .request_id = value.request_id,
        .size = value.size,
        .name = value.name[0..value.name_len],
        .launch = launch,
    };
}
