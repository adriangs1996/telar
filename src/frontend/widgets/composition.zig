//! Composition root for one client-chrome frame.
//!
//! This is deliberately linear. Reading `render` shows every visible widget,
//! its region, its order, and the only conditional replacement in the frame.

const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @import("Context.zig");
const State = @import("State.zig");
const Metrics = @import("Metrics.zig");
const CompositionOutput = @import("CompositionOutput.zig");
const top_bar = @import("top_bar.zig");
const sidebar = @import("sidebar.zig");
const Cursor = @import("Cursor.zig");
const tab_rename = @import("tab_rename.zig");
const status_bar = @import("status_bar.zig");
const workbench = @import("workbench.zig");
const BarLayoutRegions = @import("BarLayoutRegions.zig");
const tab_bar = @import("tab_bar.zig");
const bar_content = @import("bar_content.zig");

pub fn render(context: *Context, input: CompositionInput) CompositionOutput {
    top_bar.render(context, .{
        .area = input.regions.top,
        .sidebar_visible = !input.regions.sidebar.isEmpty(),
        .location = input.model.tabs.location[input.tab],
        .workspace_name = input.model.workspaceName(),
        .workspaces = input.workspaces,
        .collapsed = input.workspace_list_collapsed,
        .proxy_tls_active = input.proxy_tls_active,
        .proxy_tls_scope = input.proxy_tls_scope,
        .proxy_system_trusted = input.proxy_system_trusted,
        .right = input.bar_state.layout.slot(.top_right),
        .system_metrics = input.system_metrics,
    });

    const focused_agent = block: {
        const location = input.model.tabs.location[input.tab];
        const pane_id = input.model.tabs.layout[input.tab].focused() orelse break :block null;
        break :block input.sidebar_snapshot.keyForPane(location, pane_id);
    };
    const sidebar_output = sidebar.render(context, .{
        .area = input.regions.sidebar,
        .snapshot = input.sidebar_snapshot,
        .state = input.sidebar_state,
        .model = input.model,
        .tab = input.tab,
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

    context.buffer.fill(input.regions.bottom, .{ .glyph = " ", .style = bottomStyle(context) });
    const cursor: ?Cursor = if (input.rename_field) |field|
        tab_rename.render(context, .{
            .area = input.regions.bottom,
            .field = field,
            .kind = input.rename_kind,
            .prompt = input.prompt,
            .path_completion = input.path_completion,
        })
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

fn renderBottom(context: *Context, input: CompositionInput) void {
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
    const regions = BarLayoutRegions.calculate(input.regions.bottom, .{
        .desired = desired,
        .tabs_index = tab_index,
    });

    for (slots, regions.items, 0..) |*slot, area, index| {
        const alignment: data.bar_values.Alignment = switch (index) {
            0 => .left,
            1 => .center,
            else => .right,
        };
        switch (slot.*) {
            .empty => {},
            .tabs => tab_bar.render(context, .{
                .area = area,
                .model = input.model,
                .tab = input.tab,
                .alignment = alignment,
                .animation_frame = input.sidebar_animation_frame,
            }),
            .metrics => status_bar.render(context, area, input.system_metrics),
            .content => |*content| bar_content.render(context, area, .{
                .content = content,
                .alignment = alignment,
            }),
        }
    }
}

fn bottomDesiredWidth(slot: *const data.bar_values.Slot, input: CompositionInput) u16 {
    return switch (slot.*) {
        .empty => 0,
        .content => |*content| content.width(),
        .metrics => status_bar.desiredWidth(input.system_metrics),
        .tabs => tab_bar.desiredWidth(.{
            .area = input.regions.bottom,
            .model = input.model,
            .tab = input.tab,
        }),
    };
}

fn bottomStyle(context: *const Context) core.Style {
    return .{
        .fg = context.palette.subtext0,
        .bg = context.palette.panel_bg,
    };
}

const CompositionInput = struct {
    regions: data.GridRegions,
    model: *const data.ClientModel,
    /// The active tab's slot in `model.tabs`.
    tab: usize,
    layout: *const data.LayoutSnapshot,
    rename_field: ?*tab_rename.Field,
    rename_kind: tab_rename.Kind,
    prompt: ?*const data.Prompt = null,
    path_completion: ?*const data.PathCompletionState = null,
    sidebar_snapshot: *const data.AgentSnapshot,
    sidebar_state: *State,
    sidebar_transparent: bool,
    sidebar_rounded_focus: bool,
    sidebar_animation_frame: u8,
    proxy_tls_active: bool,
    proxy_tls_scope: core.ProxyScope = .exact,
    proxy_system_trusted: bool = false,
    system_metrics: ?Metrics,
    status_mode: client.Mode,
    workspaces: *const data.WorkspaceListSnapshot,
    workspace_list_collapsed: bool,
    bar_state: *const data.BarsState,
};
