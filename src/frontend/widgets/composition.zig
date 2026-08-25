//! Composition root for one client-chrome frame.
//!
//! This is deliberately linear. Reading `render` shows every visible widget,
//! its region, its order, and the only conditional replacement in the frame.

const multiplexer = @import("../multiplexer.zig");
const tabs_mod = @import("../tabs.zig");
const context_mod = @import("context.zig");
const layout = @import("layout.zig");
const sidebar = @import("sidebar.zig");
const status_bar = @import("status_bar.zig");
const tab_bar = @import("tab_bar.zig");
const tab_rename = @import("tab_rename.zig");
const top_bar = @import("top_bar.zig");
const ui = @import("../ui.zig");
const workbench = @import("workbench.zig");

pub const Input = struct {
    regions: layout.Regions,
    tabs: ?*const tabs_mod.Model,
    model: *multiplexer.Model,
    rename_field: ?*tab_rename.Field,
    sidebar_snapshot: *const sidebar.Snapshot,
    sidebar_state: *sidebar.State,
    sidebar_transparent: bool,
    proxy_tls_active: bool,
};

pub const Output = struct {
    sidebar: sidebar.Semantic,
    cursor: ?context_mod.Cursor,
};

pub fn render(context: *context_mod.Context, input: Input) Output {
    top_bar.render(context, .{
        .area = input.regions.top,
        .sidebar_visible = !input.regions.sidebar.isEmpty(),
        .location = input.model.location,
        .workspace_name = if (input.tabs) |tabs| tabs.workspaceName() else "",
    });

    const sidebar_output = sidebar.render(context, .{
        .area = input.regions.sidebar,
        .snapshot = input.sidebar_snapshot,
        .state = input.sidebar_state,
        .transparent = input.sidebar_transparent,
    });

    context.buffer.fill(input.regions.bottom, " ", bottomStyle(context));
    const cursor = if (input.rename_field) |field|
        tab_rename.render(context, input.regions.bottom, field)
    else block: {
        tab_bar.render(context, .{
            .area = input.regions.tabs,
            .tabs = input.tabs,
            .model = input.model,
        });
        status_bar.render(context, input.regions.status, input.model, input.proxy_tls_active);
        break :block null;
    };

    workbench.register(context, input.regions.workbench, input.model);
    return .{
        .sidebar = sidebar_output,
        .cursor = if (cursor) |value| value else sidebar_output.cursor,
    };
}

fn bottomStyle(context: *const context_mod.Context) ui.Style {
    return .{
        .fg = context.palette.subtext0,
        .bg = context.palette.panel_bg,
    };
}
