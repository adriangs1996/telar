const OwnedCreateWorkspace = @This();
const source_namespace = @import("outbox_support.zig");
request_id: source_namespace.schema.RequestId,
size: source_namespace.schema.TerminalSize,
name: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
name_len: u8,
launch: source_namespace.schema.Launch,

pub fn view(value: *const OwnedCreateWorkspace, cwd: []const u8) source_namespace.schema.CreateWorkspace {
    var launch = value.launch;
    launch.cwd = cwd;

    return .{
        .request_id = value.request_id,
        .size = value.size,
        .name = value.name[0..value.name_len],
        .launch = launch,
    };
}
