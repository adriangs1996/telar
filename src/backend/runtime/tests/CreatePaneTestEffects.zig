const Effects = @This();
const pane_mod = @import("../../pane/root.zig");
const create_pane_commands = @import("../application/commands/create_pane.zig");
const source_namespace = @import("create_pane_test.zig");
launched: pane_mod.PaneLaunched,
attachment_count: usize = 0,
event_count: usize = 0,

pub fn panes(effects: *Effects) create_pane_commands.TabPanes {
    return .{ .context = effects, .has_running = hasRunning };
}

pub fn authority(effects: *Effects) create_pane_commands.LaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn launcher(effects: *Effects) create_pane_commands.PaneLauncher {
    return .{ .context = effects, .launch = launch };
}

pub fn attachment(effects: *Effects) create_pane_commands.PaneAttachment {
    return .{ .context = effects, .attach = attach };
}

pub fn publisher(effects: *Effects) create_pane_commands.EventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn hasRunning(_: *anyopaque, _: source_namespace.schema.TabLocation) bool {
    return true;
}

fn prepare(_: *anyopaque, _: create_pane_commands.PrepareLaunch) ![]const u8 {
    return "/work/project";
}

fn launch(context: *anyopaque, _: create_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return effects.launched;
}

fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn publish(context: *anyopaque, _: pane_mod.PaneLaunched) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
}
