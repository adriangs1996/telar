const PaneIdType = @import("telar-core").PaneId;
const WorkspaceCreatedType = @import("../../workspace/WorkspaceCreated.zig");
const CreateWorkspaceLaunchAuthority = @import("../application/commands/CreateWorkspaceLaunchAuthority.zig");
const CreateWorkspaceGeometryLease = @import("../application/commands/CreateWorkspaceGeometryLease.zig");
const CreateWorkspacePaneLauncher = @import("../application/commands/CreateWorkspacePaneLauncher.zig");
const ClientAttachmentType = @import("../application/commands/ClientAttachment.zig");
const CreateWorkspaceEventPublisher = @import("../application/commands/CreateWorkspaceEventPublisher.zig");
const CreateWorkspacePrepareLaunch = @import("../application/commands/CreateWorkspacePrepareLaunch.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const CreateWorkspaceLaunchPane = @import("../application/commands/CreateWorkspaceLaunchPane.zig");
const CreateWorkspaceLaunchedPane = @import("../application/commands/CreateWorkspaceLaunchedPane.zig");
const Effects = @This();

pane_id: PaneIdType,
attachment_count: usize = 0,
event_count: usize = 0,
last_event: ?WorkspaceCreatedType = null,

pub fn authority(effects: *Effects) CreateWorkspaceLaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn geometry(effects: *Effects) CreateWorkspaceGeometryLease {
    return .{
        .context = effects,
        .acquire = acquire,
        .release = release,
    };
}

pub fn launcher(effects: *Effects) CreateWorkspacePaneLauncher {
    return .{ .context = effects, .launch = launch };
}

pub fn attachment(effects: *Effects) ClientAttachmentType {
    return .{ .context = effects, .replace = replace };
}

pub fn publisher(effects: *Effects) CreateWorkspaceEventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn prepare(_: *anyopaque, _: CreateWorkspacePrepareLaunch) ![]const u8 {
    return "/work/new";
}

fn acquire(_: *anyopaque, _: WorkspaceLocationType) bool {
    return true;
}

fn release(_: *anyopaque, _: WorkspaceLocationType) void {
    unreachable;
}

fn launch(context: *anyopaque, _: CreateWorkspaceLaunchPane) !CreateWorkspaceLaunchedPane {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return .{ .id = effects.pane_id };
}

fn replace(context: *anyopaque, _: CreateWorkspaceLaunchedPane) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn publish(context: *anyopaque, event: WorkspaceCreatedType) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
    effects.last_event = event;
}
