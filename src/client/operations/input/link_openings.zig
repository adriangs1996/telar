//! Wires link intents to tab creation and bounded host workers.
const std = @import("std");
const core = @import("telar-core");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const pane_focus = @import("../panes/pane_focus.zig");

const Client = @import("../../AttachedClient.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const MouseType = @import("../../input/Mouse.zig");
const Command = @import("../../links/PointerCommand.zig");
const RectType = @import("telar-core").Rect;
const extract_module = @import("../../links/cells.zig").extract;
const FilePathType = @import("../../links/FilePath.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const pane_splits = @import("../panes/pane_splits.zig");
const PaneId = @import("telar-core").PaneId;
const notification_flow = @import("../notifications/notifications.zig");

/// Dispatches one owned target without letting opener failures leave input.
///
/// ```zig
/// _ = try apply(client, target);
/// ```
pub fn apply(client: *Client, target: TargetType) !bool {
    const result = switch (target.scheme) {
        .file => open: {
            const path = FilePathType.init(&target) catch |err| {
                try reportFailure(client, err);
                return false;
            };
            break :open openFile(client, path);
        },
        .http, .https, .external => openExternal(client, target),
    };
    result catch |err| {
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
pub fn pointer(client: *Client, model: *MultiplexerModel, event: MouseType) !bool {
    const command: Command = .{
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
        targetAt(model, event, client.geometry().area)
    else
        null;
    const outcome = client.link_pointer.handle(command, target);
    if (outcome.open) |selected| {
        _ = try apply(client, selected);
    }

    if (outcome.copy) |selected| {
        try client.host_clipboard.set(client.host_clipboard.context, selected.uri());
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

fn targetAt(model: *MultiplexerModel, event: MouseType, area: RectType) ?TargetType {
    const plan = model.planPaneMouse(event, area) orelse return null;
    const pane = model.findConst(plan.pane_id) orelse return null;

    return extract_module(&pane.buffer, pane.scroll, .{
        .x = event.x - plan.content.x,
        .y = pane.scroll.offset + event.y - plan.content.y,
    });
}

fn openFile(client: *Client, path: FilePathType) !void {
    const editor = client.editorExecutable();
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    _ = try tab_creations.request(client, .{ .arguments = &.{ editor, path.slice() } });
}

fn openExternal(client: *Client, target: TargetType) !void {
    switch (client.link_opening.request(target)) {
        .queued => {},
        .start => |selected| startExternal(client, selected) catch |err| {
            client.link_opening.schedulingFailed();

            return err;
        },
    }
}

fn startExternal(client: *Client, target: TargetType) !void {
    try client.link_opener.start(target);
}

fn reportFailure(client: *Client, err: anyerror) !void {
    try notification_flow.publishNow(client, .{
        .level = .warning,
        .title = "Could not open link",
        .message = @errorName(err),
    });
}

/// Reuses a reachable editor in the source tab, otherwise creates a sibling pane.
/// Example: `_ = try openMessageFile(client, pane_id, path);`
pub fn openMessageFile(client: *Client, pane_id: PaneId, path: FilePathType) !bool {
    openEditorPane(client, pane_id, path) catch |err| {
        try reportFailure(client, err);
        return false;
    };

    return true;
}

fn openEditorPane(client: *Client, pane_id: PaneId, path: FilePathType) !void {
    const editor = client.editorExecutable();
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    const model = client.model.activeTabModel() orelse return error.PaneNotFound;
    const source = model.findConst(pane_id) orelse return error.PaneNotFound;
    var request: core.OwnedEditorOpen = .{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = source.pane_generation,
    };
    try request.setTarget(editor, path.slice());
    const kind = core.editor.identify(editor);
    var reusable = false;
    if (kind != .unsupported and source.pane_generation != 0) {
        var panes = model.paneConstIterator();
        while (panes.next()) |pane| {
            reusable = reusable or core.editor.identify(pane.foregroundName()) == kind;
        }
    }

    if (!reusable) {
        return splitEditorPane(client, request);
    }

    request.request_id = try client.request_lifecycle.nextId();
    try client.editor_open.begin(request);
    errdefer _ = client.editor_open.complete(request.request_id);
    try request_lifecycle.deliver(client, .{
        .registration = .{ .request_id = request.request_id, .continuation = .{ .editor_open = .{
            .pane_id = pane_id,
            .pane_generation = source.pane_generation,
            .attachment_generation = source.attachment_generation,
            .location = source.location,
        } } },
        .message = .{ .open_editor = request.view() },
    });
}

/// Applies a correlated reply only while the originating view still exists.
/// Example: `try editorOpened(client, reply);`
pub fn editorOpened(client: *Client, reply: core.EditorOpened) !void {
    const request = client.editor_open.complete(reply.request_id) orelse return;
    const continuation = request_lifecycle.consume(client, reply.request_id) orelse return;
    if (continuation != .editor_open) {
        return;
    }

    const operation = continuation.editor_open;
    const model = client.model.activeTabModel() orelse return;
    const source = model.findConst(operation.pane_id) orelse return;
    if (source.pane_generation != operation.pane_generation or source.attachment_generation != operation.attachment_generation or !std.meta.eql(source.location, operation.location)) {
        return;
    }

    switch (reply.outcome) {
        .unavailable => splitEditorPane(client, request) catch |err| try reportFailure(client, err),
        .failed => try reportFailure(client, error.EditorOpenFailed),
        .opened => {
            const pane = model.findConst(reply.pane_id) orelse return;
            if (pane.pane_generation != reply.pane_generation) {
                return;
            }

            _ = try pane_focus.apply(client, .{ .target = .{ .pane_id = reply.pane_id }, .area = client.geometry().area });
        },
    }
}

fn splitEditorPane(client: *Client, request: core.OwnedEditorOpen) !void {
    const plan = try pane_splits.request(client, .{
        .axis = .horizontal,
        .area = client.geometry().area,
        .target_pane = request.pane_id,
        .arguments = &.{ request.editor(), request.path() },
    });
    if (plan == null) {
        return error.PaneSplitUnavailable;
    }
}
