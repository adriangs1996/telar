//! Host services execute as bounded inbox producers.
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");

/// Example: `app.link_opener = services.links(app);`
pub fn links(app: *client.AttachedClient) client.LinkOpener {
    return .{ .context = app, .open = openLink };
}

fn openLink(context: *anyopaque, target: client.LinkTarget) !void {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    try GuiClient.of(app).driver.inbox.start(.link_opened, .{ client.openHostLink, .{ app.io, target } });
}
