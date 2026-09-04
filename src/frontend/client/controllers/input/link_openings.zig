//! Wires link intents to tab creation and bounded host workers.

const core = @import("telar-core");
const link_capability = @import("../../../links/root.zig");
const presentation = @import("../../../presentation/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("../../application/input/root.zig");
const notification_flow = @import("../notifications/notifications.zig");
const tab_creations = @import("../tabs/tab_creations.zig");

const Client = @import("../../client.zig");
const multiplexer = workspace_capability.multiplexer;
const open_link = input_application.open_link;
const term = presentation.screen;

/// Dispatches one owned target without letting opener failures leave input.
///
/// ```zig
/// _ = try apply(client, target);
/// ```
pub fn apply(client: *Client, target: link_capability.Target) !bool {
    var handler: open_link.OpenLinkHandler = .{
        .effects = .{
            .context = client,
            .open_file = openFile,
            .open_external = openExternal,
        },
    };
    handler.execute(target) catch |err| {
        try reportFailure(client, err);

        return false;
    };

    return true;
}

/// Gives a textual link first refusal before child mouse reporting.
///
/// ```zig
/// if (try pointer(client, model, event)) return;
/// ```
pub fn pointer(client: *Client, model: *multiplexer.Model, event: term.Event.Mouse) !bool {
    const command: link_capability.PointerCommand = .{
        .kind = switch (event.kind) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            else => .other,
        },
        .left_button = event.button & 0b11 == 0,
    };
    const target = if (command.kind == .press and command.left_button)
        targetAt(model, event, client.view.workbench())
    else
        null;
    const outcome = client.link_pointer.handle(command, target);
    if (outcome.open) |selected| {
        _ = try apply(client, selected);
    }

    return outcome.consumed;
}

/// Completes one host worker and starts the last target queued behind it.
///
/// ```zig
/// try complete(client, result);
/// ```
pub fn complete(client: *Client, result: anyerror!void) !void {
    if (result) |_| {} else |err| {
        try reportFailure(client, err);
    }

    const next = client.link_opening.complete() orelse return;
    startExternal(client, next) catch |err| {
        client.link_opening.schedulingFailed();
        try reportFailure(client, err);
    };
}

fn targetAt(model: *multiplexer.Model, event: term.Event.Mouse, area: core.ui.Rect) ?link_capability.Target {
    const plan = model.planPaneMouse(event, area) orelse return null;
    const pane = model.findConst(plan.pane_id) orelse return null;

    return link_capability.extract(&pane.buffer, pane.scroll, .{
        .x = event.x - plan.content.x,
        .y = pane.scroll.offset + event.y - plan.content.y,
    });
}

fn openFile(raw_context: *anyopaque, path: link_capability.FilePath) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const editor = client.options.editor;
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    var handler = tab_creations.requestHandler(client);
    _ = try handler.execute(.{ .arguments = &.{ editor, path.slice() } });
}

fn openExternal(raw_context: *anyopaque, target: link_capability.Target) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    switch (client.link_opening.request(target)) {
        .queued => {},
        .start => |selected| startExternal(client, selected) catch |err| {
            client.link_opening.schedulingFailed();

            return err;
        },
    }
}

fn startExternal(client: *Client, target: link_capability.Target) !void {
    try client.select.concurrent(.link_opened, link_capability.host.open, .{ client.io, target });
}

fn reportFailure(client: *Client, err: anyerror) !void {
    try notification_flow.publishNow(client, .{
        .level = .warning,
        .title = "Could not open link",
        .message = @errorName(err),
    });
}
