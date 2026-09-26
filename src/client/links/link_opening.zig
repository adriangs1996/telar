//! Link opening: resolves the link under the pointer and opens it with the
//! host, one at a time.
const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const editorremote = @import("editorremote");
const data = @import("model");
const core = @import("telar-core");
const editor_file_links = @import("editor_file_links.zig");
const notifications = @import("../notifications/notifications.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const Client = @import("../execution/Client.zig");

/// Dispatches one owned target without letting opener failures leave input.
/// A file link or a path from `source` opens in that pane's editor flow,
/// anchored at its directory and at the line the link names; without a
/// source pane an absolute file opens in a new tab.
/// Example: `_ = try link_opening.openLink(app, target, pane_id);`
pub fn openLink(client: *Client, target: data.LinkTarget, source: ?core.PaneId) !bool {
    const result = switch (target.scheme) {
        .file, .path => open: {
            const path = data.FilePath.init(&target) catch |err| {
                try reportLinkFailure(client, err);
                return false;
            };

            if (source) |pane_id| {
                return editor_file_links.openFile(client, pane_id, path);
            }

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
pub fn inputLinkPointer(client: *Client, tab: usize, event: keyinput.Mouse) !bool {
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

    const found = if (command.kind == .press and (command.left_button or command.right_button) and event.button & 4 == 0)
        linkAt(
            &client.model,
            tab,
            event,
            client.geometry().area,
        )
    else
        null;
    const outcome = client.model.link_pointer.handle(command, if (found) |link| link.target else null);
    if (outcome.open) |selected| {
        _ = try openLink(client, selected, if (found) |link| link.pane_id else null);
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

/// A link under the pointer and the pane it was printed in.
const PaneLink = struct {
    target: data.LinkTarget,
    pane_id: core.PaneId,
};

fn linkAt(model: *data.ClientModel, tab: usize, event: keyinput.Mouse, area: cellgrid.Rect) ?PaneLink {
    const plan = data.tab_layout.planPaneMouse(model, tab, event, area) orelse return null;
    const pane = model.panes.findInConst(model.tabs.location[tab].tab_id, plan.pane_id) orelse return null;
    const target = data.cells.extract(
        &pane.buffer,
        pane.scroll,
        .{
            .x = event.x - plan.content.x,
            .y = pane.scroll.offset + event.y - plan.content.y,
        },
    ) orelse return null;

    return .{
        .target = target,
        .pane_id = plan.pane_id,
    };
}

fn openLinkFile(client: *Client, path: data.FilePath) !void {
    const editor = editor_file_links.editorExecutable(client);
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    // Without a pane there is no directory to anchor a relative path to.
    if (path.slice()[0] != '/') {
        return error.RelativeFileLink;
    }

    var launch: editorremote.Launch = .{};
    _ = try tab_creation.requestTabCreation(
        client,
        .{
            .arguments = try launch.argv(editor, path.slice(), path.line, path.column),
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
