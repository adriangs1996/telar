//! Editor file links: opens a file link in the editor pane of its tab,
//! splitting one when none is reachable.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const link_opening = @import("link_opening.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_split = @import("../panes/pane_split.zig");
const Client = @import("../AttachedClient.zig");

/// Uses the current generation so editor changes take effect after reload.
/// Example: `const executable = editor_file_links.editorExecutable(client);`
pub fn editorExecutable(client: *const Client) []const u8 {
    if (client.lua_generation) |generation| {
        return generation.snapshot.resolveEditor(client.options.editor);
    }

    return client.options.editor;
}

/// Reuses a reachable editor in the source tab, otherwise creates a sibling pane.
/// Example: `_ = try editor_file_links.openMessageFile(app, pane_id, path);`
pub fn openMessageFile(client: *Client, pane_id: core.PaneId, path: data.FilePath) !bool {
    openEditorPane(client, pane_id, path) catch |err| {
        try link_opening.reportLinkFailure(client, err);
        return false;
    };

    return true;
}

fn openEditorPane(client: *Client, pane_id: core.PaneId, path: data.FilePath) !void {
    const editor = editorExecutable(client);
    if (editor.len == 0) {
        return error.EditorUnavailable;
    }

    const model = client.model.tabs.activeSlot() orelse return error.PaneNotFound;
    const source = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, pane_id) orelse return error.PaneNotFound;
    var request: core.OwnedEditorOpen = .{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = source.pane_generation,
    };

    try request.setTarget(editor, path.slice());
    const kind = core.editor.identify(editor);
    var reusable = false;
    if (kind != .unsupported and source.pane_generation != 0) {
        var panes = client.model.panes.iterateConst(client.model.tabs.location[model].tab_id);
        while (panes.next()) |pane| {
            reusable = reusable or core.editor.identify(pane.foregroundName()) == kind;
        }
    }

    if (!reusable) {
        return splitEditorPane(client, request);
    }

    request.request_id = try client.model.request_lifecycle.nextId();
    try client.model.editor_open.begin(request);
    errdefer _ = client.model.editor_open.complete(request.request_id);
    try runtime_io.sendRuntimeRequest(
        client,
        .{
            .registration = .{
                .request_id = request.request_id,
                .continuation = .{
                    .editor_open = .{
                        .pane_id = pane_id,
                        .pane_generation = source.pane_generation,
                        .attachment_generation = source.attachment_generation,
                        .location = source.location,
                    },
                },
            },
            .message = .{
                .open_editor = request.view(),
            },
        },
    );
}

/// Applies a correlated reply only while the originating view still exists.
pub fn completeEditorOpen(client: *Client, reply: core.EditorOpened) !void {
    const request = client.model.editor_open.complete(reply.request_id) orelse return;
    const continuation = client.model.request_lifecycle.tracker.take(reply.request_id) orelse return;
    if (continuation != .editor_open) {
        return;
    }

    const operation = continuation.editor_open;
    const model = client.model.tabs.activeSlot() orelse return;
    const source = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, operation.pane_id) orelse return;
    if (source.pane_generation != operation.pane_generation or source.attachment_generation != operation.attachment_generation or !std.meta.eql(source.location, operation.location)) {
        return;
    }

    switch (reply.outcome) {
        .unavailable => splitEditorPane(client, request) catch |err| try link_opening.reportLinkFailure(client, err),
        .failed => try link_opening.reportLinkFailure(client, error.EditorOpenFailed),
        .opened => {
            const pane = client.model.panes.findInConst(client.model.tabs.location[model].tab_id, reply.pane_id) orelse return;
            if (pane.pane_generation != reply.pane_generation) {
                return;
            }

            _ = try pane_focus.applyPaneFocus(
                client,
                .{
                    .target = .{
                        .pane_id = reply.pane_id,
                    },
                    .area = client.geometry().area,
                },
            );
        },
    }
}

fn splitEditorPane(client: *Client, request: core.OwnedEditorOpen) !void {
    const plan = try pane_split.requestPaneSplit(
        client,
        .{
            .axis = .horizontal,
            .area = client.geometry().area,
            .target_pane = request.pane_id,
            .arguments = &.{
                request.editor(),
                request.path(),
            },
        },
    );
    if (plan == null) {
        return error.PaneSplitUnavailable;
    }
}
