//! Frame pacing, preparation and delivery over the window-owned presentation state.

const client = @import("telar-client");
const data = @import("model");
const cellgrid = @import("cellgrid");
const selection = @import("render/copy_selection.zig");
const LinkTooltip = @import("widgets/LinkTooltip.zig");
const Renderer = @import("render/Renderer.zig");
const CursorTarget = @import("CursorTarget.zig");
const WindowModel = @import("WindowModel.zig");

pub fn statusMode(model: *const WindowModel, app: *const client.Client) client.Mode {
    if (!model.router.prefixPending()) {
        return if (client.copy_mode.copyModeActive(app)) .copy else .normal;
    }

    var hints: client.Hints = .{};
    const actions = [_]data.actions.Action{
        .{
            .split_pane = .horizontal,
        },
        .{
            .split_pane = .vertical,
        },
        .new_tab,
        .new_workspace,
        .rename_tab,
        .rename_workspace,
        .close_pane,
        .enter_copy_mode,
    };

    const labels = [_][]const u8{
        "split right",
        "split down",
        "new tab",
        "new workspace",
        "rename tab",
        "rename workspace",
        "close pane",
        "copy mode",
    };

    for (actions, labels) |action, label| {
        const key = model.router.prefixedKeyForAction(action) orelse continue;
        hints.append(
            .{
                .key = key,
                .label = label,
            },
        );
    }

    return .{
        .prefix = hints,
    };
}

/// Copies the visible cursor identity for the native blink clock.
/// Example: `clock.observe(cursorTarget(gui.app), now_ns);`
pub fn cursorTarget(app: *client.Client) CursorTarget {
    if (app.model.name_prompt.active()) {
        return .{};
    }

    const tab = app.model.tabs.activeSlot() orelse return .{};
    const pane = data.tab_layout.focusedPaneConst(&app.model, tab) orelse return .{};
    const copy = data.copy_mode.currentProjection(&app.model);
    const copy_view: ?data.CopyModeView = if (copy) |value| if (value.pane_id == pane.id) value.view else null else null;
    const cursor = selection.cursor(pane, copy_view);
    const layout = data.tab_layout.snapshot(&app.model, tab, data.workbench.region(&app.model).area);
    for (layout.views()) |view| {
        if (view.pane_id == pane.id and cursor.x < view.content.w and cursor.y < view.content.h) {
            return .{
                .pane_id = pane.id,
                .generation = pane.attachment_generation,
                .cursor = cursor,
            };
        }
    }

    return .{};
}

/// Applies a dragged or stepped sidebar width: the preference changes and
/// the next preparation measures the grid again.
/// Example: `adoptSidebarWidth(&gui.model, command.sidebar_width.?);`
pub fn adoptSidebarWidth(model: *WindowModel, width: u32) void {
    if (model.sidebar.drag(width)) {
        model.chrome.invalidate();
    }
}

/// The host cells the hovered link's tooltip will cover in the prepared frame.
pub fn tooltipCover(model: *const WindowModel, renderer: *const Renderer) ?cellgrid.Rect {
    const hit = if (model.pointer.hover.link) |*value| value else return null;
    const area = LinkTooltip.place(hit, renderer.metrics, renderer.origin, renderer.chrome) orelse return null;
    return LinkTooltip.cover(area, renderer.metrics, renderer.origin);
}

pub fn ingress(model: *const WindowModel) client.PresentationIngress {
    return .{
        .input_routing = model.binding_revision,
        .view_interaction = model.chrome.revision +% model.pointer.hover.revision +% model.widgets.dispatcher.revision,
    };
}
