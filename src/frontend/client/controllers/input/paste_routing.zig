//! Wires streamed host paste ownership to prompt and pane paste use cases.

const Client = @import("../../Client.zig");
const ApplicationInputPasteRoutingOutcome = @import("telar-client").ApplicationInputPasteRoutingOutcome;
const ApplicationInputPasteRoutingCommand = @import("telar-client").ApplicationInputPasteRoutingCommand;
const PasteRoutingHandlerType = @import("telar-client").PasteRoutingHandler;
const PasteRoutingAuthority = @import("telar-client").PasteRoutingAuthority;
const RouteType = @import("telar-client").Route;
const name_prompts = @import("name_prompts.zig");
const pane_pastes = @import("pane_pastes.zig");

/// Routes one opening boundary using the current client authority.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !ApplicationInputPasteRoutingOutcome {
    return dispatch(client, .start);
}

/// Routes one borrowed content chunk to the owner established at start.
///
/// ```zig
/// _ = try content(client, bytes);
/// ```
pub fn content(client: *Client, text: []const u8) !ApplicationInputPasteRoutingOutcome {
    return dispatch(client, .{ .content = text });
}

/// Routes one closing boundary and lets the established owner release itself.
///
/// ```zig
/// _ = try finish(client);
/// ```
pub fn finish(client: *Client) !ApplicationInputPasteRoutingOutcome {
    return dispatch(client, .finish);
}

fn dispatch(client: *Client, command: ApplicationInputPasteRoutingCommand) !ApplicationInputPasteRoutingOutcome {
    var use_case: PasteRoutingHandlerType = .{
        .effects = .{
            .context = client,
            .route = route,
        },
    };

    return use_case.execute(snapshot(client), command);
}

fn snapshot(client: *const Client) PasteRoutingAuthority {
    const prompt = client.model.name_prompt.currentConst();

    return .{
        .attachment_modal_active = client.view.hasAttachmentModal(),
        .prompt_active = prompt != null,
        .prompt_pasting = if (prompt) |value| value.pasting else false,
        .copy_mode_active = client.model.copyModeActive(),
        .pane_paste_active = client.model.panePasteActive(),
    };
}

fn route(raw_context: *anyopaque, value: RouteType) !void {
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
