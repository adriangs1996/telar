//! Wires host-key ownership policy to existing client input use cases.

const Client = @import("../../Client.zig");
const captures_module = @import("telar-client").captures;
const ApplicationInputKeyRoutingCommand = @import("telar-client").ApplicationInputKeyRoutingCommand;
const KeyRoutingOutcome = @import("telar-client").KeyRoutingOutcome;
const KeyRoutingHandlerType = @import("telar-client").KeyRoutingHandler;
const KeyRoutingAuthority = @import("telar-client").KeyRoutingAuthority;
const encodeKey_module = @import("telar-client").encodeKey;
const name_prompts = @import("name_prompts.zig");
const KeyType = @import("telar-client").Key;
const copy_modes = @import("copy_modes.zig");
const PaneCommandType = @import("telar-client").PaneCommand;
const PaneIdType = @import("telar-core").PaneId;
const pane_inputs = @import("pane_inputs.zig");
const attachment_prompts = @import("attachment_prompts.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const clipboard_images = @import("../host/clipboard_images.zig");

/// Returns whether modal or prompt authority must bypass configured bindings.
/// Copy mode deliberately leaves native bindings available.
///
/// ```zig
/// if (captures(client)) routeDirectly();
/// ```
pub fn captures(client: *const Client) bool {
    return captures_module(authority(client));
}

/// Routes one semantic key or borrowed byte slice to a single current owner.
///
/// ```zig
/// const outcome = try apply(client, .{ .key = key });
/// ```
pub fn apply(client: *Client, command: ApplicationInputKeyRoutingCommand) !KeyRoutingOutcome {
    var use_case: KeyRoutingHandlerType = .{
        .leases = &client.host_input.application_leases,
        .effects = .{
            .context = client,
            .close_modal = closeModal,
            .prompt = routePrompt,
            .copy_key = routeCopyKey,
            .pane = routePane,
            .preview = startPreview,
        },
    };

    const outcome = try use_case.execute(command, authority(client));
    client.telemetry.metrics.key_lease_overflows +%= @intFromBool(outcome.lease_overflow);

    return outcome;
}

fn authority(client: *const Client) KeyRoutingAuthority {
    return .{
        .attachment_modal_active = client.view.hasAttachmentModal(),
        .prompt_active = client.model.name_prompt.active(),
        .copy_mode_active = client.model.copyModeActive(),
    };
}

fn closeModal(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = client.view.closeAttachmentModal();
}

fn routePrompt(raw_context: *anyopaque, command: ApplicationInputKeyRoutingCommand) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var encoded: [32]u8 = undefined;
    const bytes = switch (command) {
        .bytes => |value| value,
        .key => |value| try encodeKey_module(&encoded, value, .{}),
    };

    _ = try name_prompts.handleInput(client, bytes);
}

fn routeCopyKey(raw_context: *anyopaque, key: KeyType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.key(client, key);
}

fn routePane(raw_context: *anyopaque, command: PaneCommandType) !?PaneIdType {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const delivery = try pane_inputs.send(client, .{
        .target = switch (command.target) {
            .current => .focused,
            .lease => |pane_id| .{ .key_lease = pane_id },
        },
        .source = .host,
        .payload = switch (command.input) {
            .bytes => |bytes| .{ .bytes = bytes },
            .key => |key| .{ .key = key },
        },
    });

    const completed = delivery orelse return null;
    if (attachment_prompts.observe(client, completed.pane_id, command.input)) {
        kitty_delivery.invalidatePlacements(&client.graphics_store);
        try pane_geometry.offerActive(client, client.geometry().area);
    }

    return completed.pane_id;
}

fn startPreview(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try clipboard_images.start(client);
}
