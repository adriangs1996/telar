const std = @import("std");
const copy_modes = @import("../input/copy_modes.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const name_prompts = @import("../input/name_prompts.zig");
const history_palettes = @import("../input/history_palettes.zig");
const notifications = @import("../notifications/notifications.zig");
const LinkTarget = @import("../../links/LinkTarget.zig");
const link_openings = @import("../input/link_openings.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");

/// Applies one routed command within this domain. Example: `try presentation_commands.execute(client, reply);`
pub fn execute(client: *Client, reply: *core.ClientCommand) !void {
    switch (reply.action) {
        .client_clipboard_copy => {
            try client.host_clipboard.set(client.host_clipboard.context, reply.text());
            reply.length = 0;
            reply.status = .admitted;
        },
        .client_open_link => {
            const target = try LinkTarget.init(reply.text());
            if (!try link_openings.apply(client, target)) {
                return error.LinkOpeningUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .notification_dismiss => {
            if (try notifications.dismissNow(client, @enumFromInt(reply.target_id)) == null) {
                return error.NotificationNotFound;
            }

            reply.status = .applied;
        },
        .client_copy_mode => {
            if (!copy_modes.active(client) and !copy_modes.enter(client)) {
                return error.CopyModeUnavailable;
            }

            reply.status = .applied;
        },
        .client_open_history => {
            if (!try history_palettes.begin(client)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .admitted;
        },
        .client_open_goto => {
            if (!name_prompts.beginGotoPicker(client)) {
                return error.ClientPromptUnavailable;
            }

            reply.status = .applied;
        },
        .workspace_list_collapse => {
            if (client.model.setWorkspaceListCollapsed(true) != null) {
                client.chrome.setWorkspaceListCollapsed(true);
            }

            reply.status = .applied;
        },
        .workspace_list_expand => {
            if (client.model.setWorkspaceListCollapsed(false) != null) {
                client.chrome.setWorkspaceListCollapsed(false);
            }

            reply.status = .applied;
        },
        .sidebar_resize => {
            const width = std.math.cast(u16, reply.value) orelse return error.InvalidWidth;
            if (width == 0) {
                return error.InvalidWidth;
            }

            _ = try sidebar_toggles.resize(client, .{ .exact = width });
            try sidebarState(client, reply);
        },
        .sidebar_hide => {
            if (client.model.sidebarVisible()) {
                _ = try sidebar_toggles.toggle(
                    client,
                );
            }

            try sidebarState(client, reply);
        },
        .sidebar_show => {
            if (!client.model.sidebarVisible()) {
                _ = try sidebar_toggles.toggle(
                    client,
                );
            }

            try sidebarState(client, reply);
        },
        .sidebar_get => {
            try sidebarState(client, reply);
        },
        else => return error.InvalidClientCommand,
    }
}

fn sidebarState(client: *const Client, reply: *core.ClientCommand) !void {
    reply.value = client.model.sidebarWidth();
    try reply.setText(if (client.model.sidebarVisible()) "visible" else "hidden");
    reply.status = .applied;
}
