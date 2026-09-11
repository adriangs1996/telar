const PaneLaunchedType = @import("../../pane/PaneLaunched.zig");
const TabPanesType = @import("../application/commands/TabPanes.zig");
const CreatePaneLaunchAuthority = @import("../application/commands/CreatePaneLaunchAuthority.zig");
const CreatePaneLauncher = @import("../application/commands/CreatePaneLauncher.zig");
const CreatePaneAttachment = @import("../application/commands/CreatePaneAttachment.zig");
const CreatePaneEventPublisher = @import("../application/commands/CreatePaneEventPublisher.zig");
const TabLocationType = @import("telar-core").TabLocation;
const CreatePanePrepareLaunch = @import("../application/commands/CreatePanePrepareLaunch.zig");
const CreatePaneLaunchPane = @import("../application/commands/CreatePaneLaunchPane.zig");
const Effects = @This();

launched: PaneLaunchedType,
attachment_count: usize = 0,
event_count: usize = 0,

pub fn panes(effects: *Effects) TabPanesType {
    return .{ .context = effects, .has_running = hasRunning };
}

pub fn authority(effects: *Effects) CreatePaneLaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn launcher(effects: *Effects) CreatePaneLauncher {
    return .{ .context = effects, .launch = launch };
}

pub fn attachment(effects: *Effects) CreatePaneAttachment {
    return .{ .context = effects, .attach = attach };
}

pub fn publisher(effects: *Effects) CreatePaneEventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn hasRunning(_: *anyopaque, _: TabLocationType) bool {
    return true;
}

fn prepare(_: *anyopaque, _: CreatePanePrepareLaunch) ![]const u8 {
    return "/work/project";
}

fn launch(context: *anyopaque, _: CreatePaneLaunchPane) !PaneLaunchedType {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return effects.launched;
}

fn attach(context: *anyopaque, _: PaneLaunchedType) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn publish(context: *anyopaque, _: PaneLaunchedType) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
}
