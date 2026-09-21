const layout_commands = @import("layout_commands.zig");
const config_reloads = @import("../configuration/config_reloads.zig");
const config_queries = @import("../configuration/config_queries.zig");
const plugin_queries = @import("../configuration/plugin_queries.zig");
const plugin_toggles = @import("../configuration/plugin_toggles.zig");
const plugin_invocations = @import("../configuration/plugin_invocations.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const pane_commands = @import("pane_commands.zig");
const navigation_commands = @import("navigation_commands.zig");
const presentation_commands = @import("presentation_commands.zig");
const agent_commands = @import("agent_commands.zig");

/// Executes a semantic command in this client's disposable state. Example: `try client_commands.apply(client, command);`
pub fn apply(client: *Client, command: core.ClientCommand) !void {
    var reply = command;
    execute(client, &reply) catch |err| {
        reply.status = .failed;
        try reply.setText(@errorName(err));
    };
    try client.sendRuntimeClientCompletion(reply);
}

fn execute(client: *Client, reply: *core.ClientCommand) !void {
    if (reply.status != .request) {
        return error.InvalidClientCommand;
    }

    switch (reply.action) {
        .plugin_run => {
            try plugin_invocations.run(client, reply);
        },
        .plugin_disable => {
            try plugin_toggles.disable(client, reply);
        },
        .plugin_enable => {
            try plugin_toggles.enable(client, reply);
        },
        .plugin_get => {
            try plugin_queries.get(client, reply);
        },
        .plugin_list => {
            try plugin_queries.list(client, reply);
        },
        .config_show => {
            try config_queries.show(client, reply);
        },
        .config_reload => {
            try config_reloads.request(client);
            reply.status = .admitted;
        },
        .layout_apply => {
            try layout_commands.apply(client, reply);
        },
        .layout_get => {
            try layout_commands.get(client, reply);
        },
        .pane_copy, .pane_scroll, .pane_fullscreen, .pane_resize, .pane_focus, .pane_close, .pane_split, .pane_create => try pane_commands.execute(client, reply),
        .tab_previous, .tab_next, .tab_select, .tab_create, .workspace_select => try navigation_commands.execute(client, reply),
        .client_clipboard_copy, .client_open_link, .notification_dismiss, .client_copy_mode, .client_open_history, .client_open_goto, .workspace_list_collapse, .workspace_list_expand, .sidebar_resize, .sidebar_hide, .sidebar_show, .sidebar_get => try presentation_commands.execute(client, reply),
        .agent_view_collapse, .agent_view_expand, .agent_draft_attach, .agent_draft_set, .agent_draft_get, .agent_create => try agent_commands.execute(client, reply),
    }
}
