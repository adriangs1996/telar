//! Wires host-key ownership policy to existing client input use cases.

const key_routing = @import("../../application/input/key_routing.zig");
const Routed = @import("../../application/input/Routed.zig");
const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const captures_module = @import("../../application/input/key_routing.zig").captures;
const ApplicationInputKeyRoutingCommand = @import("../../application/input/key_routing.zig").Command;
const KeyRoutingOutcome = @import("../../application/input/KeyRoutingOutcome.zig");
const KeyRoutingAuthority = @import("../../application/input/KeyRoutingAuthority.zig");
const name_prompts = @import("name_prompts.zig");
const KeyType = @import("../../input/Key.zig");
const copy_modes = @import("copy_modes.zig");
const PaneCommandType = @import("../../application/input/PaneCommand.zig");
const PaneIdType = @import("telar-core").PaneId;
const pane_inputs = @import("pane_inputs.zig");
const attachment_prompts = @import("attachment_prompts.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const clipboard_images = @import("../host/clipboard_images.zig");

/// Returns whether modal or prompt authority must bypass configured bindings.
/// Copy mode deliberately leaves native bindings available.
///
/// ```zig
/// if (captures(client)) routeDirectly();
/// ```
pub fn captures(client: *const Client) bool {
    return captures_module(snapshotAuthority(client));
}

/// Routes one semantic key or borrowed byte slice to a single current owner.
///
/// ```zig
/// const outcome = try apply(client, .{ .key = key });
/// ```
pub fn apply(client: *Client, command: ApplicationInputKeyRoutingCommand) !KeyRoutingOutcome {
    const current = snapshotAuthority(client);
    const outcome = switch (command) {
        .bytes => |bytes| if (bytes.len == 0) KeyRoutingOutcome{ .owner = .ignored } else (try routeCurrent(client, command, current)).outcome,
        .key => |key| try routeKey(client, key, current),
    };
    client.telemetry.metrics.key_lease_overflows +%= @intFromBool(outcome.lease_overflow);
    return outcome;
}

fn snapshotAuthority(client: *const Client) KeyRoutingAuthority {
    return .{
        .attachment_modal_active = client.attachment_shelf.modalActive(),
        .prompt_active = client.model.name_prompt.active(),
        .copy_mode_active = client.model.copyModeActive(),
    };
}

fn closeModal(client: *Client) void {
    _ = client.attachment_shelf.closeModal();
}

fn routePrompt(client: *Client, command: ApplicationInputKeyRoutingCommand) !void {
    switch (command) {
        .key => |value| _ = try name_prompts.handleInput(client, .{ .key = value }),
        .bytes => |bytes| try client.host_input_source.routePromptBytes(bytes),
    }
}

fn routeCopyKey(client: *Client, key: KeyType) !void {
    _ = try copy_modes.key(client, key);
}

fn routePane(client: *Client, command: PaneCommandType) !?PaneIdType {
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
        client.host_graphics.invalidatePlacements();
        try pane_geometry.offerActive(client, client.geometry().area);
    }

    return completed.pane_id;
}

fn startPreview(client: *Client) !void {
    _ = try clipboard_images.start(client);
}

fn routeKey(client: *Client, key: KeyType, authority: KeyRoutingAuthority) !KeyRoutingOutcome {
    const identity = key.physical orelse return (try routeCurrent(client, .{ .key = key }, authority)).outcome;

    return switch (key.phase) {
        .press => routePress(client, key, authority),
        .repeat => routeRepeat(client, key, client.input_leases.owner(identity) orelse return .{ .owner = .ignored }),
        .release => routeRelease(client, key, client.input_leases.release(identity) orelse return .{ .owner = .ignored }),
    };
}

fn routePress(client: *Client, key: KeyType, authority: KeyRoutingAuthority) !KeyRoutingOutcome {
    const identity = key.physical.?;
    if (!client.input_leases.acquire(identity, .ignored)) {
        return .{ .owner = .ignored, .lease_overflow = true };
    }
    errdefer _ = client.input_leases.release(identity);

    const routed = try routeCurrent(client, .{ .key = key }, authority);
    const assigned = client.input_leases.acquire(identity, routed.lease_owner);
    std.debug.assert(assigned);

    return routed.outcome;
}

fn routeRepeat(client: *Client, key: KeyType, owner: key_routing.LeaseOwner) !KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{ .owner = .ignored },
        .attachment_modal => .{ .owner = .attachment_modal },
        .name_prompt => prompt: {
            try routePrompt(client, .{ .key = key });

            break :prompt .{ .owner = .name_prompt };
        },
        .copy_mode => copy: {
            try routeCopyKey(client, key);

            break :copy .{ .owner = .copy_mode };
        },
        .pane => |pane_id| routeLeasedPane(client, key, pane_id),
    };
}

fn routeRelease(client: *Client, key: KeyType, owner: key_routing.LeaseOwner) !KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{ .owner = .ignored },
        .attachment_modal => .{ .owner = .attachment_modal },
        .name_prompt => .{ .owner = .name_prompt },
        .copy_mode => .{ .owner = .copy_mode },
        .pane => |pane_id| routeLeasedPane(client, key, pane_id),
    };
}

fn routeCurrent(client: *Client, command: key_routing.Command, authority: KeyRoutingAuthority) !Routed {
    switch (command) {
        .bytes => {},
        .key => |key| {
            if (authority.attachment_modal_active) {
                if (key.code == .escape) {
                    closeModal(client);
                }

                return .{
                    .outcome = .{ .owner = .attachment_modal },
                    .lease_owner = .attachment_modal,
                };
            }
        },
    }

    if (authority.prompt_active) {
        try routePrompt(client, command);

        return .{
            .outcome = .{ .owner = .name_prompt },
            .lease_owner = .name_prompt,
        };
    }

    if (authority.copy_mode_active) {
        switch (command) {
            .bytes => {},
            .key => |key| try routeCopyKey(client, key),
        }

        return .{
            .outcome = .{ .owner = .copy_mode },
            .lease_owner = .copy_mode,
        };
    }

    const pane_id = try routePane(client, .{
        .target = .current,
        .input = command,
    });
    if (pane_id != null and key_routing.requestsClipboardPreview(command)) {
        startPreview(client) catch {};
    }

    return .{
        .outcome = .{ .owner = .pane, .delivered = pane_id != null },
        .lease_owner = if (pane_id) |id| .{ .pane = id } else .ignored,
    };
}

fn routeLeasedPane(client: *Client, key: KeyType, pane_id: PaneIdType) !KeyRoutingOutcome {
    const delivered = try routePane(client, .{
        .target = .{ .lease = pane_id },
        .input = .{ .key = key },
    });

    return .{ .owner = .pane, .delivered = delivered != null };
}
