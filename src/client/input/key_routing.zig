//! Key routing: decides who owns a key press, repeat or release (a prompt,
//! a leased pane, copy mode, a binding or the focused pane) and delivers it.
const keyinput = @import("keyinput");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const agent_attachments = @import("../attachments/agent_attachments.zig");
const clipboard_capture = @import("../attachments/clipboard_capture.zig");
const copy_mode = @import("copy_mode.zig");
const name_prompt = @import("name_prompt.zig");
const pane_input = @import("../panes/pane_input.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const Client = @import("../execution/Client.zig");
const bar_updates = @import("../config/bar_updates.zig");

/// Snapshot the current exclusive keyboard owners without exposing client state.
/// Example: `const captures_keys = key_policy.captures(key_routing.keyRoutingAuthority(client));`
pub fn keyRoutingAuthority(client: *const Client) data.KeyRoutingAuthority {
    return .{
        .attachment_modal_active = if (client.attachments) |shelf| shelf.modalActive() else false,
        .prompt_active = client.model.name_prompt.active(),
        .copy_mode_active = data.copy_mode.isActive(&client.model),
    };
}

/// Routes one semantic key or borrowed byte slice to a single current owner.
/// Example: `_ = try key_routing.routeKeyInput(app, command);`
pub fn routeKeyInput(client: *Client, command: data.KeyRoutingCommand) !data.KeyRoutingOutcome {
    if (command == .key and command.key.mods.super and command.key.phase != .release) {
        return .{ .owner = .ignored };
    }

    const current = keyRoutingAuthority(client);
    const outcome = switch (command) {
        .bytes => |bytes| if (bytes.len == 0) data.KeyRoutingOutcome{
            .owner = .ignored,
        } else (try routeCurrentKey(client, command, current)).outcome,
        .key => |key| try routePhysicalKey(client, key, current),
    };
    client.telemetry.metrics.key_lease_overflows +%= @intFromBool(outcome.lease_overflow);
    return outcome;
}

fn routePromptInput(client: *Client, command: data.KeyRoutingCommand) !void {
    switch (command) {
        .key => |value| _ = try name_prompt.inputPrompt(
            client,
            .{
                .key = value,
            },
        ),
        .bytes => |bytes| try client.host_input_source.routePromptBytes(bytes),
    }
}

fn routePaneKey(client: *Client, command: data.PaneCommand) !?core.PaneId {
    const delivery = try pane_input.sendPaneInput(
        client,
        .{
            .target = switch (command.target) {
                .current => .focused,
                .lease => |pane_id| .{
                    .key_lease = pane_id,
                },
            },
            .source = .host,
            .payload = switch (command.input) {
                .bytes => |bytes| .{
                    .bytes = bytes,
                },
                .key => |key| .{
                    .key = key,
                },
            },
        },
    );

    const completed = delivery orelse return null;
    if (agent_attachments.observeAttachmentInput(client, completed.pane_id, command.input)) {
        client.model.to_host.invalidate_placements = true;
        if (client.model.tabs.activeSlot()) |tab| {
            try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
        }
    }

    return completed.pane_id;
}

fn routePhysicalKey(client: *Client, key: keyinput.Key, authority: data.KeyRoutingAuthority) !data.KeyRoutingOutcome {
    const identity = key.physical orelse return (try routeCurrentKey(
        client,
        .{
            .key = key,
        },
        authority,
    )).outcome;

    return switch (key.phase) {
        .press => routeKeyPress(client, key, authority),
        .repeat => routeKeyRepeat(client, key, client.model.input_leases.owner(identity) orelse return .{
            .owner = .ignored,
        }),
        .release => routeKeyRelease(client, key, client.model.input_leases.release(identity) orelse return .{
            .owner = .ignored,
        }),
    };
}

fn routeKeyPress(client: *Client, key: keyinput.Key, authority: data.KeyRoutingAuthority) !data.KeyRoutingOutcome {
    const identity = key.physical.?;
    if (!client.model.input_leases.acquire(identity, .ignored)) {
        return .{
            .owner = .ignored,
            .lease_overflow = true,
        };
    }
    errdefer _ = client.model.input_leases.release(identity);

    const routed = try routeCurrentKey(
        client,
        .{
            .key = key,
        },
        authority,
    );
    const assigned = client.model.input_leases.acquire(identity, routed.lease_owner);
    std.debug.assert(assigned);

    return routed.outcome;
}

fn routeKeyRepeat(client: *Client, key: keyinput.Key, owner: data.KeyRoutingLeaseOwner) !data.KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{
            .owner = .ignored,
        },
        .attachment_modal => .{
            .owner = .attachment_modal,
        },
        .name_prompt => prompt: {
            try routePromptInput(
                client,
                .{
                    .key = key,
                },
            );

            break :prompt .{
                .owner = .name_prompt,
            };
        },
        .copy_mode => copy: {
            _ = try copy_mode.applyCopyMode(
                client,
                .{
                    .key = key,
                },
            );

            break :copy .{
                .owner = .copy_mode,
            };
        },
        .pane => |pane_id| routeLeasedPaneKey(client, key, pane_id),
    };
}

fn routeKeyRelease(client: *Client, key: keyinput.Key, owner: data.KeyRoutingLeaseOwner) !data.KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{
            .owner = .ignored,
        },
        .attachment_modal => .{
            .owner = .attachment_modal,
        },
        .name_prompt => .{
            .owner = .name_prompt,
        },
        .copy_mode => .{
            .owner = .copy_mode,
        },
        .pane => |pane_id| routeLeasedPaneKey(client, key, pane_id),
    };
}

fn routeCurrentKey(client: *Client, command: data.KeyRoutingCommand, authority: data.KeyRoutingAuthority) !data.Routed {
    switch (command) {
        .bytes => {},
        .key => |key| {
            if (authority.attachment_modal_active) {
                if (key.code == .escape) {
                    if (client.attachments) |shelf| {
                        _ = shelf.closeModal();
                    }
                }

                return .{
                    .outcome = .{
                        .owner = .attachment_modal,
                    },
                    .lease_owner = .attachment_modal,
                };
            }

            // Escape dismisses the bar panel before a prompt or pane sees it.
            if (!authority.prompt_active and keyinput.keybind.isPlainEscape(key) and client.model.bars.panel.isOpen()) {
                try bar_updates.closePanel(client);
                return .{
                    .outcome = .{
                        .owner = .ignored,
                    },
                    .lease_owner = .ignored,
                };
            }
        },
    }

    if (authority.prompt_active) {
        try routePromptInput(client, command);

        return .{
            .outcome = .{
                .owner = .name_prompt,
            },
            .lease_owner = .name_prompt,
        };
    }

    if (authority.copy_mode_active) {
        switch (command) {
            .bytes => {},
            .key => |key| _ = try copy_mode.applyCopyMode(
                client,
                .{
                    .key = key,
                },
            ),
        }

        return .{
            .outcome = .{
                .owner = .copy_mode,
            },
            .lease_owner = .copy_mode,
        };
    }

    const pane_id = try routePaneKey(
        client,
        .{
            .target = .current,
            .input = command,
        },
    );
    if (pane_id != null and data.key_routing.requestsClipboardPreview(command)) {
        _ = clipboard_capture.startClipboardCapture(&client.model) catch {};
    }

    return .{
        .outcome = .{
            .owner = .pane,
            .delivered = pane_id != null,
        },
        .lease_owner = if (pane_id) |id| .{
            .pane = id,
        } else .ignored,
    };
}

fn routeLeasedPaneKey(client: *Client, key: keyinput.Key, pane_id: core.PaneId) !data.KeyRoutingOutcome {
    const delivered = try routePaneKey(
        client,
        .{
            .target = .{
                .lease = pane_id,
            },
            .input = .{
                .key = key,
            },
        },
    );

    return .{
        .owner = .pane,
        .delivered = delivered != null,
    };
}
