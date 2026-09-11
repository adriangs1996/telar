const Effects = @This();
const pane_mod = @import("../../pane/root.zig");
const open_pane_commands = @import("../application/commands/open_pane.zig");
const source_namespace = @import("open_pane_test.zig");
launched: pane_mod.PaneLaunched,
event_count: usize = 0,
attachment_count: usize = 0,

pub fn panes(effects: *Effects) open_pane_commands.Panes {
    return .{
        .context = effects,
        .find = find,
        .first = first,
        .launch = launch,
        .prepare_view = prepareView,
        .attach = attach,
    };
}

pub fn authority(effects: *Effects) open_pane_commands.LaunchAuthority {
    return .{ .context = effects, .prepare = prepare };
}

pub fn geometry(effects: *Effects) open_pane_commands.GeometryLease {
    return .{
        .context = effects,
        .acquire = acquire,
        .release = release,
    };
}

pub fn publisher(effects: *Effects) open_pane_commands.EventPublisher {
    return .{ .context = effects, .publish = publish };
}

fn find(_: *anyopaque, _: source_namespace.schema.PaneId) ?pane_mod.PaneLaunched {
    return null;
}

fn first(_: *anyopaque, _: source_namespace.schema.TabLocation) ?pane_mod.PaneLaunched {
    return null;
}

fn launch(context: *anyopaque, _: open_pane_commands.LaunchPane) !pane_mod.PaneLaunched {
    const effects: *Effects = @ptrCast(@alignCast(context));
    return effects.launched;
}

fn prepareView(_: *anyopaque, _: open_pane_commands.PrepareView) !void {}

fn attach(context: *anyopaque, _: pane_mod.PaneLaunched) !void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.attachment_count += 1;
}

fn prepare(_: *anyopaque, _: open_pane_commands.PrepareLaunch) ![]const u8 {
    return "/work/new";
}

fn acquire(_: *anyopaque, _: source_namespace.schema.WorkspaceLocation) bool {
    return true;
}

fn release(_: *anyopaque, _: source_namespace.schema.WorkspaceLocation) void {
    unreachable;
}

fn publish(context: *anyopaque, _: open_pane_commands.RuntimeEvent) void {
    const effects: *Effects = @ptrCast(@alignCast(context));
    effects.event_count += 1;
}
