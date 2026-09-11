const KeyRoutingEffects = @import("KeyRoutingEffects.zig");
const key_routing = @import("key_routing.zig");
const KeyRoutingAuthority = @import("KeyRoutingAuthority.zig");
const KeyRoutingOutcome = @import("KeyRoutingOutcome.zig");
const KeyType = @import("../../input/Key.zig");
const std = @import("std");
const Routed = @import("Routed.zig");
const PaneIdType = @import("telar-core").PaneId;
const KeyRoutingHandler = @This();

effects: KeyRoutingEffects,
leases: *key_routing.Leases,

/// Assigns one synchronous input value to exactly one owner. A successful
/// unmodified Ctrl+V pane delivery may start one best-effort media preview.
///
/// ```zig
/// const outcome = try handler.execute(command, authority);
/// ```
pub fn execute(handler: *KeyRoutingHandler, command: key_routing.Command, authority: KeyRoutingAuthority) !KeyRoutingOutcome {
    return switch (command) {
        .bytes => |bytes| if (bytes.len == 0)
            .{ .owner = .ignored }
        else
            (try handler.routeCurrent(command, authority)).outcome,
        .key => |key| handler.routeKey(key, authority),
    };
}

fn routeKey(handler: *KeyRoutingHandler, key: KeyType, authority: KeyRoutingAuthority) !KeyRoutingOutcome {
    const identity = key.physical orelse return (try handler.routeCurrent(.{ .key = key }, authority)).outcome;

    return switch (key.phase) {
        .press => handler.routePress(key, authority),
        .repeat => handler.routeRepeat(key, handler.leases.owner(identity) orelse return .{ .owner = .ignored }),
        .release => handler.routeRelease(key, handler.leases.release(identity) orelse return .{ .owner = .ignored }),
    };
}

fn routePress(handler: *KeyRoutingHandler, key: KeyType, authority: KeyRoutingAuthority) !KeyRoutingOutcome {
    const identity = key.physical.?;
    if (!handler.leases.acquire(identity, .ignored)) {
        return .{ .owner = .ignored, .lease_overflow = true };
    }
    errdefer _ = handler.leases.release(identity);

    const routed = try handler.routeCurrent(.{ .key = key }, authority);
    const assigned = handler.leases.acquire(identity, routed.lease_owner);
    std.debug.assert(assigned);

    return routed.outcome;
}

fn routeRepeat(handler: *KeyRoutingHandler, key: KeyType, owner: key_routing.LeaseOwner) !KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{ .owner = .ignored },
        .attachment_modal => .{ .owner = .attachment_modal },
        .name_prompt => prompt: {
            try handler.effects.prompt(handler.effects.context, .{ .key = key });

            break :prompt .{ .owner = .name_prompt };
        },
        .copy_mode => copy: {
            try handler.effects.copy_key(handler.effects.context, key);

            break :copy .{ .owner = .copy_mode };
        },
        .pane => |pane_id| handler.routeLeasedPane(key, pane_id),
    };
}

fn routeRelease(handler: *KeyRoutingHandler, key: KeyType, owner: key_routing.LeaseOwner) !KeyRoutingOutcome {
    return switch (owner) {
        .ignored => .{ .owner = .ignored },
        .attachment_modal => .{ .owner = .attachment_modal },
        .name_prompt => .{ .owner = .name_prompt },
        .copy_mode => .{ .owner = .copy_mode },
        .pane => |pane_id| handler.routeLeasedPane(key, pane_id),
    };
}

fn routeCurrent(handler: *KeyRoutingHandler, command: key_routing.Command, authority: KeyRoutingAuthority) !Routed {
    switch (command) {
        .bytes => {},
        .key => |key| {
            if (authority.attachment_modal_active) {
                if (key.code == .escape) {
                    handler.effects.close_modal(handler.effects.context);
                }

                return .{
                    .outcome = .{ .owner = .attachment_modal },
                    .lease_owner = .attachment_modal,
                };
            }
        },
    }

    if (authority.prompt_active) {
        try handler.effects.prompt(handler.effects.context, command);

        return .{
            .outcome = .{ .owner = .name_prompt },
            .lease_owner = .name_prompt,
        };
    }

    if (authority.copy_mode_active) {
        switch (command) {
            .bytes => {},
            .key => |key| try handler.effects.copy_key(handler.effects.context, key),
        }

        return .{
            .outcome = .{ .owner = .copy_mode },
            .lease_owner = .copy_mode,
        };
    }

    const pane_id = try handler.effects.pane(handler.effects.context, .{
        .target = .current,
        .input = command,
    });
    if (pane_id != null and key_routing.requestsClipboardPreview(command)) {
        handler.effects.preview(handler.effects.context) catch {};
    }

    return .{
        .outcome = .{ .owner = .pane, .delivered = pane_id != null },
        .lease_owner = if (pane_id) |id| .{ .pane = id } else .ignored,
    };
}

fn routeLeasedPane(handler: *KeyRoutingHandler, key: KeyType, pane_id: PaneIdType) !KeyRoutingOutcome {
    const delivered = try handler.effects.pane(handler.effects.context, .{
        .target = .{ .lease = pane_id },
        .input = .{ .key = key },
    });

    return .{ .owner = .pane, .delivered = delivered != null };
}
