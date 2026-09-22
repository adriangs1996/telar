const core = @import("telar-core");
const OwnedCreateWorkspace = @This();

request_id: core.RequestId,
size: core.TerminalSize,
name: [core.max_tab_label_bytes]u8 = undefined,
name_len: u8,
launch: core.Launch,
create_cwd: bool,

pub fn view(value: *const OwnedCreateWorkspace, cwd: []const u8) core.CreateWorkspace {
    var launch = value.launch;
    launch.cwd = cwd;

    return .{
        .request_id = value.request_id,
        .size = value.size,
        .name = value.name[0..value.name_len],
        .launch = launch,
        .create_cwd = value.create_cwd,
    };
}
