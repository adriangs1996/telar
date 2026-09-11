const PaneLaunchedType = @import("../../pane/PaneLaunched.zig");
const PanesType = @import("../application/commands/Panes.zig");
const OpenPaneLaunchAuthority = @import("../application/commands/OpenPaneLaunchAuthority.zig");
const OpenPaneGeometryLease = @import("../application/commands/OpenPaneGeometryLease.zig");
const OpenPaneEventPublisher = @import("../application/commands/OpenPaneEventPublisher.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const OpenPaneLaunchPane = @import("../application/commands/OpenPaneLaunchPane.zig");
const PrepareViewType = @import("../application/commands/PrepareView.zig");
const OpenPanePrepareLaunch = @import("../application/commands/OpenPanePrepareLaunch.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const open_pane_commands = @import("../application/commands/open_pane.zig");
const Effects = @This();

launched: PaneLaunchedType,
event_count: usize = 0,
attachment_count: usize = 0,

pub fn panes(effects: *Effects) PanesType {
    return .{
        .context = effects,
        .find = find,
        .first = first,
        .launch = launch,
        .prepare_view = prepareView,
        .attach = attach,
    };
}

pub fn authority(effects: *Effects) OpenPaneLaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn geometry(effects: *Effects) OpenPaneGeometryLease {
    return .{
        .context = effects,
        .acquire = acquire,
        .release = release,
    };
}

pub fn publisher(effects: *Effects) OpenPaneEventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn find(_: *anyopaque, _: PaneIdType) ?PaneLaunchedType {
    return null;
}

fn first(_: *anyopaque, _: TabLocationType) ?PaneLaunchedType {
    return null;
}

fn launch(context: *anyopaque, _: OpenPaneLaunchPane) !PaneLaunchedType {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return effects.launched;
}

fn prepareView(_: *anyopaque, _: PrepareViewType) !void {}

fn attach(context: *anyopaque, _: PaneLaunchedType) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn prepare(_: *anyopaque, _: OpenPanePrepareLaunch) ![]const u8 {
    return "/work/new";
}

fn acquire(_: *anyopaque, _: WorkspaceLocationType) bool {
    return true;
}

fn release(_: *anyopaque, _: WorkspaceLocationType) void {
    unreachable;
}

fn publish(context: *anyopaque, _: open_pane_commands.RuntimeEvent) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
}
