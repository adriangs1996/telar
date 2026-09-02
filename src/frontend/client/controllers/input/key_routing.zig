//! Wires host-key ownership policy to existing client input use cases.

const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const input_application = @import("../../application/input/root.zig");
const attachment_prompts = @import("attachment_prompts.zig");
const clipboard_images = @import("../host/clipboard_images.zig");
const copy_modes = @import("copy_modes.zig");
const name_prompts = @import("name_prompts.zig");
const pane_inputs = @import("pane_inputs.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");

const Client = @import("../../client.zig");
const host_input = input_capability.host;
const key_routing = input_application.key_routing;
const schema = core.schema;

pub const Command = key_routing.Command;
pub const Outcome = key_routing.Outcome;

/// Returns whether modal or prompt authority must bypass configured bindings.
/// Copy mode deliberately leaves native bindings available.
///
/// ```zig
/// if (captures(client)) routeDirectly();
/// ```
pub fn captures(client: *const Client) bool {
    return key_routing.captures(authority(client));
}

/// Routes one semantic key or borrowed byte slice to a single current owner.
///
/// ```zig
/// const outcome = try apply(client, .{ .key = key });
/// ```
pub fn apply(client: *Client, command: Command) !Outcome {
    var use_case: key_routing.KeyRoutingHandler = .{
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

fn authority(client: *const Client) key_routing.Authority {
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

fn routePrompt(raw_context: *anyopaque, command: Command) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var encoded: [32]u8 = undefined;
    const bytes = switch (command) {
        .bytes => |value| value,
        .key => |value| try host_input.encodeKey(&encoded, value, .{}),
    };

    _ = try name_prompts.handleInput(client, bytes);
}

fn routeCopyKey(raw_context: *anyopaque, key: input_capability.keybind.Key) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.key(client, key);
}

fn routePane(raw_context: *anyopaque, command: key_routing.PaneCommand) !?schema.PaneId {
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
        client.graphics_store.invalidatePlacements();
        try pane_geometry.offerActive(client, client.view.workbench());
    }

    return completed.pane_id;
}

fn startPreview(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try clipboard_images.start(client);
}
