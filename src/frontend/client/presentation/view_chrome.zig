//! Keeps the terminal view drawing what the model's chrome facts say: host
//! size, sidebar layout, themes and the sidebar renderer. The view is a
//! render cache; the model stays the one copy.

const client_module = @import("telar-client");
const std = @import("std");
const TerminalClient = @import("../TerminalClient.zig");
const ChromeRevisions = @import("ChromeRevisions.zig");


/// Follows every chrome fact that changed since the last call. A failed step
/// leaves the revisions unobserved, so the next event retries it.
/// Example: `try view_chrome.refresh(terminal);`
pub fn refresh(terminal: *TerminalClient) !void {
    const model = &terminal.app.model;
    const observed: ChromeRevisions = .{
        .host = model.host.host_revision,
        .host_capabilities = model.host.host_capabilities_revision,
        .configuration = model.configuration_revision,
        .chrome = model.chrome_revision,
    };
    if (std.meta.eql(terminal.chrome_observed, observed)) {
        return;
    }

    const view = &terminal.view;
    const size = model.host.host_size;
    if (view.scratch.w != size.cols or view.scratch.h != size.rows) {
        try terminal.presenter.resize(size.cols, size.rows);
        try view.resize(size.cols, size.rows);
    }

    view.setSidebarLayout(model.sidebar_visible, model.sidebar_width);
    view.setWorkspaceListCollapsed(model.workspace_list_collapsed);
    if (!std.meta.eql(view.theme, model.theme)) {
        view.setTheme(model.theme);
    }

    view.setIconTheme(model.icon_theme);
    try view.configureSidebar(
        model.config.sidebar_rendering,
        .{
            .support = model.host.host_capabilities.images,
            .cell_width = size.cell_width_px,
            .cell_height = size.cell_height_px,
        },
    );
    terminal.chrome_observed = observed;
}

/// Example: `try view_chrome.refreshClient(client);`
pub fn refreshClient(client: *client_module.AttachedClient) !void {
    try refresh(TerminalClient.of(client));
}
