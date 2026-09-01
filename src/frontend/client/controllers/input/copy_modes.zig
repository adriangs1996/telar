//! Adapts client ports to the copy-mode application use case.

const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const input_application = @import("../../application/input/root.zig");
const pane_viewports = @import("../panes/pane_viewports.zig");

const Client = @import("../../client.zig");
const copy_mode = input_application.copy_mode;
const keybind = input_capability.keybind;
const runtime_transport = @import("../../connection/runtime_transport.zig");
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

/// Applies one runtime search reply to the active copy-mode state.
///
/// ```zig
/// _ = try matches(client, view);
/// ```
pub fn matches(client: *Client, view: schema.PaneMatchesView) !copy_mode.Outcome {
    var storage: [input_capability.copy_mode.max_matches]schema.SearchMatch = undefined;
    var count: usize = 0;
    var iterator = view.matches();
    while (try iterator.next()) |match| {
        if (count == storage.len) break;
        storage[count] = match;
        count += 1;
    }

    var use_case = handler(client);
    return use_case.execute(.{ .matches = .{ .pane_id = view.pane_id, .matches = storage[0..count] } });
}

fn handler(client: *Client) copy_mode.CopyModeHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .copy = copySelection,
            .open_search = openSearch,
            .viewport = pane_viewports.effects(client),
        },
    };
}

fn openSearch(context: *anyopaque, direction: input_capability.copy_mode.Direction) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const name_prompts = @import("name_prompts.zig");

    _ = name_prompts.beginCopySearch(client, direction);
}

fn copySelection(context: *anyopaque, selection: schema.CopySelection) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .copy_selection = selection });
}
