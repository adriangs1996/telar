const core = @import("telar-core");
const OwnedCreateWorkspace = @This();

request_id: core.RequestId,
size: core.TerminalSize,
name: [core.max_tab_label_bytes]u8 = undefined,
name_len: u8,
launch: core.Launch,
create_cwd: bool,

pub fn view(self: *const OwnedCreateWorkspace, cwd: []const u8) core.CreateWorkspace {
    var launch = self.launch;
    launch.cwd = cwd;

    return .{
        .request_id = self.request_id,
        .size = self.size,
        .name = self.name[0..self.name_len],
        .launch = launch,
        .create_cwd = self.create_cwd,
    };
}
