//! Link opening: resolves the link under the pointer and opens it with the
//! host, one at a time.
const data = @import("model");
const core = @import("telar-core");
const editor_file_links = @import("editor_file_links.zig");
const notifications = @import("../notifications/notifications.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const Client = @import("../AttachedClient.zig");

/// Dispatches one owned target without letting opener failures leave input.
/// Example: `_ = try link_opening.openLink(app, target);`
pub fn openLink(client: *Client, target: data.LinkTarget) !bool {
    const result = switch (target.scheme) {
        .file => open: {
            const path = data.FilePath.init(&target) catch |err| {
                try reportLinkFailure(client, err);
                return false;
            };

            break :open openLinkFile(client, path);
        },
        .http, .https, .external => openExternalLink(client, target),
    };

    result catch |err| {
        try reportLinkFailure(client, err);
        return false;
    };

    return true;
}

/// Gives a textual link first refusal before child mouse reporting.
/// Example: `_ = try link_opening.inputLinkPointer(app, tab, event);`
pub fn inputLinkPointer(client: *Client, tab: usize, event: data.Mouse) !bool {
    const command: data.LinksPointerCommand = .{
        .kind = switch (event.kind) {
            .press => .press,
            .release => .release,
            .drag => .drag,
            else => .other,
        },
        .left_button = event.button & 0b11 == 0,
        .right_button = event.button & 0b11 == 2,
    };

    const target = if (command.kind == .press and (command.left_button or command.right_button) and event.button & 4 == 0)
        linkTargetAt(
            &client.model,
            tab,
            event,
            client.geometry().area,
        )
    else
        null;
    const outcome = client.model.link_pointer.handle(command, target);
    if (outcome.open) |selected| {
        _ = try openLink(client, selected);
    }

    if (outcome.copy) |selected| {
        try client.model.to_host.writeClipboard(client.gpa, selected.uri());
    }

    return outcome.consumed;
}

/// Completes one host worker and starts the last target queued behind it.
/// Example: `try link_opening.completeLinkOpening(app, result);`
pub fn completeLinkOpening(client: *Client, result: anyerror!void) !void {
    if (result) |_| {} else |err| {
        try reportLinkFailure(client, err);
    }

    const next = client.model.link_opening.complete() orelse return;
    client.to_workers.push(.{ .link = next }) catch |err| {
        client.model.link_opening.schedulingFailed();
        try reportLinkFailure(client, err);
    };
}

fn linkTargetAt(model: *data.ClientModel, tab: usize, event: data.Mouse, area: core.Rect) ?data.LinkTarget {
    const plan = data.tab_layout.planPaneMouse(model, tab, event, area) orelse return null;
    const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, plan.pane_id) orelse return null;

    return data.cells.extract(
        &pane.buffer,
        pane.scroll,
        .{
            .x = event.x - plan.content.x,
            .y = pane.scroll.offset + event.y - plan.content.y,
        },
    );
}

fn openLinkFile(client: *Client, path: data.FilePath) !void {
    const editor = editor_file_links.editorExecutable(client);
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    _ = try tab_creation.requestTabCreation(
        client,
        .{
            .arguments = &.{
                editor,
                path.slice(),
            },
        },
    );
}

fn openExternalLink(client: *Client, target: data.LinkTarget) !void {
    switch (client.model.link_opening.request(target)) {
        .queued => {},
        .start => |selected| client.to_workers.push(.{ .link = selected }) catch |err| {
            client.model.link_opening.schedulingFailed();

            return err;
        },
    }
}

pub fn reportLinkFailure(client: *Client, err: anyerror) !void {
    try notifications.publishNotificationNow(
        client,
        .{
            .level = .warning,
            .title = "Could not open link",
            .message = @errorName(err),
        },
    );
}
