//! A pointer activating a bar or panel component: it opens the component's
//! `url` through the link opener, or runs its action. `open_panel` remembers
//! the component so the panel appears above it.
const data = @import("model");
const bar_updates = @import("../config/bar_updates.zig");
const actions = @import("actions.zig");
const link_opening = @import("../links/link_opening.zig");
const Client = @import("../execution/Client.zig");

/// Example: `try bar_components.activate(client, .{ .position = .bottom_right, .node = 3 });`
pub fn activate(client: *Client, component: data.BarComponent) !void {
    const content = client.model.bars.layout.content(component.position) orelse return;
    if (component.node >= content.node_count) {
        return;
    }

    const node = content.slice()[component.node];
    if (content.action(node)) |action| {
        if (action == .open_panel) {
            return bar_updates.togglePanel(client, .{
                .index = action.open_panel,
                .anchor = component,
            });
        }

        _ = try actions.executeAction(client, action, .binding);
        return;
    }

    try openUrl(client, content.text(node.url));
}

/// Activates a button of the open panel, by its index in the panel.
/// Example: `try bar_components.activatePanel(client, 4);`
pub fn activatePanel(client: *Client, index: u8) !void {
    const content = &client.model.bars.panel.content;
    if (index >= content.node_count) {
        return;
    }

    const node = content.slice()[index];
    if (content.action(node)) |action| {
        _ = try actions.executeAction(client, action, .binding);
        return;
    }

    try openUrl(client, content.text(node.url));
}

fn openUrl(client: *Client, url: []const u8) !void {
    if (url.len == 0) {
        return;
    }

    // Parsing accepted only http(s) destinations; a URL the link scanner
    // still refuses is dropped rather than opened.
    const target = data.LinkTarget.init(url) catch return;
    _ = try link_opening.openLink(client, target, null);
}
