//! Wires streamed host paste ownership to prompt and pane paste use cases.

const input_application = @import("../../application/input/root.zig");
const name_prompts = @import("name_prompts.zig");
const pane_pastes = @import("pane_pastes.zig");

const Client = @import("../../client.zig");
const paste_routing = input_application.paste_routing;

pub const Outcome = paste_routing.Outcome;

/// Routes one opening boundary using the current client authority.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !Outcome {
    return dispatch(client, .start);
}

/// Routes one borrowed content chunk to the owner established at start.
///
/// ```zig
/// _ = try content(client, bytes);
/// ```
pub fn content(client: *Client, text: []const u8) !Outcome {
    return dispatch(client, .{ .content = text });
}

/// Routes one closing boundary and lets the established owner release itself.
///
/// ```zig
/// _ = try finish(client);
/// ```
pub fn finish(client: *Client) !Outcome {
    return dispatch(client, .finish);
}

fn dispatch(client: *Client, command: paste_routing.Command) !Outcome {
    var use_case: paste_routing.PasteRoutingHandler = .{
        .effects = .{
            .context = client,
            .route = route,
        },
    };

    return use_case.execute(snapshot(client), command);
}

fn snapshot(client: *const Client) paste_routing.Authority {
    const prompt = client.model.name_prompt.currentConst();

    return .{
        .attachment_modal_active = client.view.hasAttachmentModal(),
        .prompt_active = prompt != null,
        .prompt_pasting = if (prompt) |value| value.pasting else false,
        .copy_mode_active = client.model.copyModeActive(),
        .pane_paste_active = client.model.panePasteActive(),
    };
}

fn route(raw_context: *anyopaque, value: paste_routing.Route) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    switch (value.owner) {
        .prompt => switch (value.command) {
            .start => _ = try name_prompts.handleInput(client, "\x1b[200~"),
            .content => |text| _ = try name_prompts.handleInput(client, text),
            .finish => _ = try name_prompts.handleInput(client, "\x1b[201~"),
        },
        .pane => switch (value.command) {
            .start => _ = try pane_pastes.start(client),
            .content => |text| _ = try pane_pastes.content(client, text),
            .finish => _ = try pane_pastes.finish(client),
        },
    }
}
