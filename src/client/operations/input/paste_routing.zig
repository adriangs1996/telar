//! Wires streamed host paste ownership to prompt and pane paste use cases.

const routing = @import("../../application/input/paste_routing.zig");
const Client = @import("../../AttachedClient.zig");
const ApplicationInputPasteRoutingOutcome = @import("../../application/input/paste_routing.zig").Outcome;
const ApplicationInputPasteRoutingCommand = @import("../../application/input/paste_routing.zig").Command;
const PasteRoutingAuthority = @import("../../application/input/PasteRoutingAuthority.zig");
const RouteType = @import("../../application/input/Route.zig");
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
    const owner = routing.resolve(snapshot(client), command) orelse return .ignored;
    try route(client, .{ .owner = owner, .command = command });
    return switch (owner) {
        .prompt => .prompt_owned,
        .pane => .pane_owned,
    };
}

fn snapshot(client: *const Client) PasteRoutingAuthority {
    const prompt = client.model.name_prompt.currentConst();

    return .{
        .attachment_modal_active = client.attachment_shelf.modalActive(),
        .prompt_active = prompt != null,
        .prompt_pasting = if (prompt) |value| value.pasting else false,
        .copy_mode_active = client.model.copyModeActive(),
        .pane_paste_active = client.model.panePasteActive(),
    };
}

fn route(client: *Client, value: RouteType) !void {
    switch (value.owner) {
        .prompt => switch (value.command) {
            .start => _ = try name_prompts.handleInput(client, .paste_start),
            .content => |text| _ = try name_prompts.handleInput(client, .{ .paste_text = text }),
            .finish => _ = try name_prompts.handleInput(client, .paste_end),
        },
        .pane => switch (value.command) {
            .start => _ = try pane_pastes.start(client),
            .content => |text| _ = try pane_pastes.content(client, text),
            .finish => _ = try pane_pastes.finish(client),
        },
    }
}
