//! Adapts client ports to the copy-mode application use case.

const core = @import("telar-core");
const input_capability = @import("../input/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const copy_mode = client_application.copy_mode;
const keybind = input_capability.keybind;
const schema = core.schema;

/// Enters copy mode on the attached focused pane.
///
/// ```zig
/// _ = enter(client);
/// ```
pub fn enter(client: *Client) bool {
    var use_case = handler(client);

    return use_case.enter();
}

/// Routes one host key through copy-mode semantics.
///
/// ```zig
/// _ = try key(client, pressed);
/// ```
pub fn key(client: *Client, pressed: keybind.Key) !copy_mode.Outcome {
    var use_case = handler(client);

    return use_case.execute(.{ .key = pressed });
}

/// Moves the copy cursor vertically from a host-wheel delta.
///
/// ```zig
/// _ = try vertical(client, -3);
/// ```
pub fn vertical(client: *Client, delta: i32) !copy_mode.Outcome {
    var use_case = handler(client);

    return use_case.execute(.{ .vertical = delta });
}

/// Leaves copy mode without copying the current selection.
///
/// ```zig
/// _ = try leave(client);
/// ```
pub fn leave(client: *Client) !copy_mode.Outcome {
    var use_case = handler(client);

    return use_case.execute(.leave);
}

fn handler(client: *Client) copy_mode.CopyModeHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .copy = copySelection,
            .set_viewport = setViewport,
        },
    };
}

fn copySelection(context: *anyopaque, selection: schema.CopySelection) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.enqueue(.{ .copy_selection = selection });
}

fn setViewport(context: *anyopaque, viewport: client_model.CopyModeViewport) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const active = client.model.workspace.active() orelse return error.UnexpectedCopyModeViewport;
    const pane = active.model.find(viewport.pane_id) orelse return error.UnexpectedCopyModeViewport;
    if (!pane.attached or pane.scroll.offset != viewport.offset) {
        return error.UnexpectedCopyModeViewport;
    }

    try client.graphics_store.setPaneVisible(pane.id, pane.scroll.atBottom(pane.buffer.h));
    try client.enqueue(.{ .set_pane_viewport = .{
        .pane_id = pane.id,
        .offset = viewport.offset,
    } });
}
