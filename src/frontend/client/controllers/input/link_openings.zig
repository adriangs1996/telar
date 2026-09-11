//! Wires link intents to tab creation and bounded host workers.

const Client = @import("../../Client.zig");
const TargetType = @import("telar-client").LinkTarget;
const OpenLinkHandlerType = @import("telar-client").OpenLinkHandler;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const term = @import("../../../presentation/screen_support.zig");
const Command = @import("telar-client").LinksCommandCommand;
const RectType = @import("telar-core").Rect;
const extract_module = @import("telar-client").extract;
const FilePathType = @import("telar-client").FilePath;
const tab_creations = @import("../tabs/tab_creations.zig");
const host_module = @import("../../../links/host.zig");
const notification_flow = @import("../notifications/notifications.zig");

/// Dispatches one owned target without letting opener failures leave input.
///
/// ```zig
/// _ = try apply(client, target);
/// ```
pub fn apply(client: *Client, target: TargetType) !bool {
    var handler: OpenLinkHandlerType = .{
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
pub fn pointer(client: *Client, model: *MultiplexerModel, event: term.Event.Mouse) !bool {
    const command: Command = .{
        .kind = switch (event.kind) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            else => .other,
        },
        .left_button = event.button & 0b11 == 0,
    };
    const target = if (command.kind == .press and command.left_button and event.button & 4 == 0)
        targetAt(model, event, client.geometry().area)
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

fn targetAt(model: *MultiplexerModel, event: term.Event.Mouse, area: RectType) ?TargetType {
    const plan = model.planPaneMouse(event, area) orelse return null;
    const pane = model.findConst(plan.pane_id) orelse return null;

    return extract_module(&pane.buffer, pane.scroll, .{
        .x = event.x - plan.content.x,
        .y = pane.scroll.offset + event.y - plan.content.y,
    });
}

fn openFile(raw_context: *anyopaque, path: FilePathType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const editor = client.options.editor;
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    var handler = tab_creations.requestHandler(client);
    _ = try handler.execute(.{ .arguments = &.{ editor, path.slice() } });
}

fn openExternal(raw_context: *anyopaque, target: TargetType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    switch (client.link_opening.request(target)) {
        .queued => {},
        .start => |selected| startExternal(client, selected) catch |err| {
            client.link_opening.schedulingFailed();

            return err;
        },
    }
}

fn startExternal(client: *Client, target: TargetType) !void {
    try client.select.concurrent(.link_opened, host_module.open, .{ client.io, target });
}

fn reportFailure(client: *Client, err: anyerror) !void {
    try notification_flow.publishNow(client, .{
        .level = .warning,
        .title = "Could not open link",
        .message = @errorName(err),
    });
}
