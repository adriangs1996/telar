//! Composition root for one client-chrome frame.
//!
//! This is deliberately linear. Reading `render` shows every visible widget,
//! its region, its order, and the only conditional replacement in the frame.

const workspace = @import("../workspace/root.zig");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const bars = @import("../bars/root.zig");
const layout_mod = workspace.layout;
const multiplexer = workspace.multiplexer;
const tabs_mod = workspace.tabs;
const workspace_list = workspace.workspace_list;
const context_mod = @import("context.zig");
const bar_content = @import("bar_content.zig");
const bar_layout = @import("bar_layout.zig");
const layout = @import("layout.zig");
const sidebar = @import("sidebar.zig");
const status_bar = @import("status_bar.zig");
const tab_bar = @import("tab_bar.zig");
const tab_rename = @import("tab_rename.zig");
const top_bar = @import("top_bar.zig");
const ui = @import("../ui/root.zig");
const workbench = @import("workbench.zig");

const schema = core.schema;

pub const Input = struct {
    regions: layout.Regions,
    tabs: ?*const tabs_mod.Model,
    model: *const multiplexer.Model,
    layout: *const layout_mod.Snapshot,
    rename_field: ?*tab_rename.Field,
    rename_kind: tab_rename.Kind,
    sidebar_snapshot: *const agents.Snapshot,
    sidebar_state: *sidebar.State,
    sidebar_transparent: bool,
    sidebar_rounded_focus: bool,
    sidebar_animation_frame: u8,
    proxy_tls_active: bool,
    proxy_tls_scope: schema.ProxyScope = .exact,
    system_metrics: ?status_bar.Metrics,
    status_mode: status_bar.Mode,
    workspaces: *const workspace_list.Snapshot,
    workspace_list_collapsed: bool,
    bar_state: *const bars.State,
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
        .workspace_name = if (input.tabs) |tabs| tabs.displayedWorkspaceName() else "",
        .workspaces = input.workspaces,
        .collapsed = input.workspace_list_collapsed,
        .proxy_tls_active = input.proxy_tls_active,
        .proxy_tls_scope = input.proxy_tls_scope,
        .right = input.bar_state.layout.slot(.top_right),
        .system_metrics = input.system_metrics,
    });

    const focused_agent = block: {
        const location = input.model.location orelse break :block null;
        const pane_id = input.model.layout.focused() orelse break :block null;
        break :block input.sidebar_snapshot.keyForPane(location, pane_id);
    };
    const sidebar_output = sidebar.render(context, .{
        .area = input.regions.sidebar,
        .snapshot = input.sidebar_snapshot,
        .state = input.sidebar_state,
        .active_model = input.model,
        .focused_agent = focused_agent,
        .transparent = input.sidebar_transparent,
        .rounded_focus = input.sidebar_rounded_focus,
        .animation_frame = input.sidebar_animation_frame,
    });
    if (!input.regions.sidebar.isEmpty()) {
        context.hits.add(.{
            .x = input.regions.sidebar.x + input.regions.sidebar.w - 1,
            .y = input.regions.sidebar.y,
            .w = 1,
            .h = input.regions.sidebar.h,
        }, .resize_sidebar);
    }

    context.buffer.fill(input.regions.bottom, " ", bottomStyle(context));
    const cursor: ?context_mod.Cursor = if (input.rename_field) |field|
        tab_rename.render(context, input.regions.bottom, field, input.rename_kind)
    else switch (input.status_mode) {
        .normal => block: {
            renderBottom(context, input);
            break :block null;
        },
        .prefix, .copy => block: {
            status_bar.renderMode(context, input.regions.bottom, input.status_mode);
            break :block null;
        },
    };

    workbench.register(context, input.layout);
    return .{
        .sidebar = sidebar_output,
        .cursor = if (cursor) |value| value else sidebar_output.cursor,
    };
}

fn renderBottom(context: *context_mod.Context, input: Input) void {
    const slots = &input.bar_state.layout.bottom;
    const tab_index: u2 = for (slots, 0..) |slot, index| {
        if (slot == .tabs) {
            break @intCast(index);
        }
    } else 2;
    var desired: [3]u16 = @splat(0);
    for (slots, 0..) |*slot, index| {
        desired[index] = bottomDesiredWidth(slot, input);
    }
    const regions = bar_layout.Regions.calculate(input.regions.bottom, .{
        .desired = desired,
        .tabs_index = tab_index,
    });

    for (slots, regions.items, 0..) |*slot, area, index| {
        const alignment: bars.Alignment = switch (index) {
            0 => .left,
            1 => .center,
            else => .right,
        };
        switch (slot.*) {
            .empty => {},
            .tabs => tab_bar.render(context, .{
                .area = area,
                .tabs = input.tabs,
                .model = input.model,
                .alignment = alignment,
            }),
            .metrics => status_bar.render(context, area, input.system_metrics),
            .content => |*content| bar_content.render(context, area, .{
                .content = content,
                .alignment = alignment,
            }),
        }
    }
}

fn bottomDesiredWidth(slot: *const bars.Slot, input: Input) u16 {
    return switch (slot.*) {
        .empty => 0,
        .content => |*content| content.width(),
        .metrics => status_bar.desiredWidth(input.system_metrics),
        .tabs => tab_bar.desiredWidth(.{
            .area = input.regions.bottom,
            .tabs = input.tabs,
            .model = input.model,
        }),
    };
}

fn bottomStyle(context: *const context_mod.Context) ui.Style {
    return .{
        .fg = context.palette.subtext0,
        .bg = context.palette.panel_bg,
    };
}
