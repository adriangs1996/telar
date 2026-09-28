//! Navigation across the window, sharing its row with the window's own
//! controls: room for the traffic lights, the sidebar toggle, then the tabs.
//! Above the workspace rail it names the current context before the tabs;
//! with the sidebar expanded the tabs start where the workbench starts. When
//! the window cannot hold even the rail, compact workspace indicators follow
//! the toggle as the last fallback.
const data = @import("model");
const SidebarRegions = @import("SidebarRegions.zig");
const Bands = @import("Bands.zig");
const Context = @import("Context.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Layout = gfx.Layout;
const WorkspaceIndicators = @import("WorkspaceIndicators.zig");
const TabStrip = @import("TabStrip.zig");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const PixelButton = @import("PixelButton.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const workspace_identity = @import("workspace_identity.zig");
const MachineSegment = @import("MachineSegment.zig");
const TopBar = @This();

const padding: f32 = 8;
const toggle_side: f32 = 28;
const control_height: f32 = 26;
const control_gap: f32 = 8;
const change_review_width: f32 = 36;
const context_inset: f32 = 4;
const context_max_width: f32 = 160;
const separator_gap: f32 = 10;
const separator_height: f32 = 18;

context: *const Context,
area: Rect,

/// Example: `try top_bar.draw(canvas);`
pub fn draw(self: TopBar, canvas: *Canvas) !void {
    if (self.area.width <= 0 or self.area.height <= 0) {
        return;
    }

    const chrome = canvas.chrome;
    try canvas.panelAt(self.area);

    var content = (Layout{
        .area = self.area,
        .padding = .{
            .left = chrome.px(padding),
            .right = chrome.px(padding),
        },
    }).content();

    // The slot depends only on window geometry, so detach, split and focus do
    // not animate the tabs or move delivered workspace targets underneath input.
    if (content.width >= chrome.px(160)) {
        const projection = self.context.projection;
        if (projection.tab) |tab| {
            if (data.tab_layout.focusedPaneConst(projection.model, tab)) |pane| {
                if (!projection.model.tabs.layout[tab].hasBorders()) {
                    _ = try (ChangeReviewButton{ .area = content, .pane = pane, .placement = .top_bar }).draw(canvas);
                }
            }
        }
        content.width -= chrome.px(change_review_width);
    }

    const band = canvas.sidebar;
    const right = content.x + content.width;
    const height = @min(content.height, chrome.px(control_height));
    const middle = content.y + (content.height - height) / 2;
    var left = @max(content.x, self.area.x + @as(f32, @floatFromInt(canvas.controls)));
    const side = @min(@max(0, right - left), @min(content.height, chrome.px(toggle_side)));
    const toggle: PixelButton = .{
        .context = self.context,
        .area = .{ .x = left, .y = content.y + (content.height - side) / 2, .width = side, .height = side },
        .intent = .toggle_sidebar,
        .text = "\u{2261}",
        .active = band.expanded(),
        .alignment = .center,
        .background = false,
        .hover_fill = true,
        .radius = chrome.px(8),
    };
    try toggle.draw(canvas);
    left += side + chrome.px(control_gap);

    // The machine comes first in the context: which computer, then which
    // workspace on it.
    if (MachineSegment.shown(self.context)) {
        const width = @max(0, @min(try MachineSegment.preferredWidth(canvas, self.context), (right - left) / 3));
        const segment: MachineSegment = .{
            .context = self.context,
            .area = .{ .x = left, .y = middle, .width = width, .height = height },
        };
        try segment.draw(canvas);
        left += width + chrome.px(control_gap);
    }

    if (try self.showsIndicators(canvas)) {
        const width = @max(0, @min(chrome.px(WorkspaceIndicators.preferredWidth(self.context)), @floor((right - left) / 2)));
        const indicators: WorkspaceIndicators = .{
            .context = self.context,
            .area = .{ .x = left, .y = middle, .width = width, .height = height },
        };
        try indicators.draw(canvas);
        left += width + chrome.px(control_gap);
    } else if (band.rail) {
        left += try self.drawContextName(canvas, .{ .x = left, .y = content.y, .width = @max(0, right - left), .height = content.height });
    }

    if (band.expanded()) {
        left = @max(left, @as(f32, @floatFromInt(band.reserved())));
    }

    const tabs: TabStrip = .{
        .context = self.context,
        .area = .{ .x = left, .y = self.area.y, .width = @max(0, right - left), .height = self.area.height },
    };
    try tabs.draw(canvas);
}

// Without a band the indicators are the only workspace navigation. An
// expanded sidebar too short for project rows, or a context missing from the
// list, falls back to them as well.
fn showsIndicators(self: TopBar, canvas: *Canvas) !bool {
    const band = canvas.sidebar;
    if (!band.visible()) {
        return true;
    }

    if (band.rail) {
        return false;
    }

    const active = self.context.workspaceId();
    const listed = if (active) |id| if (self.context.projection.workspaces.indexOf(id)) |index| index < self.context.projection.workspaces.project_count else false else false;
    const regions = if (self.context.sidebar_regions) |prepared| prepared.* else try SidebarRegions.resolve(canvas, Bands.resolve(canvas).sidebar, self.context.projection.workspaces.project_count, MachineSegment.shown(self.context));
    return !listed or regions.projects.height <= 0;
}

// Returns the width the name and its separator took.
fn drawContextName(self: TopBar, canvas: *Canvas, area: Rect) !f32 {
    const chrome = canvas.chrome;
    const projection = self.context.projection;
    var storage: [workspace_identity.label_bytes]u8 = undefined;
    const listed = if (self.context.workspaceId()) |id| projection.workspaces.indexOf(id) else null;
    const text = if (listed) |index| projection.workspaces.nameAt(index) else workspace_identity.contextLabel(projection.model, &storage);
    const label: Label = .{ .text = text, .color = canvas.theme.palette.text, .bold = true, .face = .sans, .size = .body };
    const inset = chrome.px(context_inset);
    const width = @min(try canvas.measure(label), @min(chrome.px(context_max_width), @max(0, area.width / 3 - inset)));
    if (width <= 0) {
        return 0;
    }

    _ = try canvas.textAt(.{ .x = area.x + inset, .y = area.y, .width = width, .height = area.height }, label);
    const gap = chrome.px(separator_gap);
    const separator_x = area.x + inset + width + gap;
    const line = @min(area.height, chrome.px(separator_height));
    try canvas.fillAt(.{ .x = @floor(separator_x), .y = @floor(area.y + (area.height - line) / 2), .width = 1, .height = line }, canvas.theme.palette.surface1);
    return inset + width + 2 * gap + 1;
}
