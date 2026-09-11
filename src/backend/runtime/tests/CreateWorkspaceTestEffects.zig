const Effects = @This();
const source_namespace = @import("create_workspace_test.zig");
const workspace_mod = @import("../../workspace/root.zig");
const create_workspace_commands = @import("../application/commands/create_workspace.zig");
pane_id: source_namespace.schema.PaneId,
attachment_count: usize = 0,
event_count: usize = 0,
last_event: ?workspace_mod.WorkspaceCreated = null,

pub fn authority(effects: *Effects) create_workspace_commands.LaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn geometry(effects: *Effects) create_workspace_commands.GeometryLease {
    return .{
        .context = effects,
        .acquire = acquire,
        .release = release,
    };
}

pub fn launcher(effects: *Effects) create_workspace_commands.PaneLauncher {
    return .{ .context = effects, .launch = launch };
}

pub fn attachment(effects: *Effects) create_workspace_commands.ClientAttachment {
    return .{ .context = effects, .replace = replace };
}

pub fn publisher(effects: *Effects) create_workspace_commands.EventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn prepare(_: *anyopaque, _: create_workspace_commands.PrepareLaunch) ![]const u8 {
    return "/work/new";
}

fn acquire(_: *anyopaque, _: source_namespace.schema.WorkspaceLocation) bool {
    return true;
}

fn release(_: *anyopaque, _: source_namespace.schema.WorkspaceLocation) void {
    unreachable;
}

fn launch(context: *anyopaque, _: create_workspace_commands.LaunchPane) !create_workspace_commands.LaunchedPane {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return .{ .id = effects.pane_id };
}

fn replace(context: *anyopaque, _: create_workspace_commands.LaunchedPane) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn publish(context: *anyopaque, event: workspace_mod.WorkspaceCreated) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
    effects.last_event = event;
}
